import Foundation
import Network
import os
import VitaKit

/// A loopback TCP server that behaves like the Vita plugin: for each accepted connection it performs the
/// current `Behavior`, normally sending one packet and closing.
///
/// It listens on `127.0.0.1` on an ephemeral port (`port`). Loopback isn't subject to Local Network
/// privacy, so tests never trigger the permission prompt.
public final class MockVitaServer: Sendable {
    public enum Behavior: Sendable, Equatable {
        /// Send `VitaPacket.encode(title)`, then close. This is the plugin's normal behaviour: 148 bytes like
        /// plugins before 1.1, or 184 bytes like plugin 1.1 when the title has a content ID.
        case packet(VitaTitle)
        /// Send these exact bytes, then close.
        case raw([UInt8])
        /// Send the bytes in pieces of `chunkSize` with `delay` between pieces, then close
        /// (exercises partial reads).
        case chunked([UInt8], chunkSize: Int, delay: Duration)
        /// Accept and keep the connection open without sending anything (exercises read timeouts).
        case silent
        /// Accept and close right away without sending anything.
        case closeImmediately
    }

    private struct State {
        var behavior: Behavior
        var connectionCount = 0
        var openConnections: [ObjectIdentifier: NWConnection] = [:]
        var isStopped = false
    }

    /// The port it is listening on.
    public let port: UInt16

    private let listener: NWListener
    private let state: OSAllocatedUnfairLock<State>

    /// Starts listening. Returns once the listener is ready.
    public init(behavior: Behavior) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "MockVitaServer")
        let state = OSAllocatedUnfairLock(initialState: State(behavior: behavior))
        listener.newConnectionHandler = { connection in
            Self.accept(connection, state: state, queue: queue)
        }
        port = try await Self.start(listener, queue: queue)
        self.listener = listener
        self.state = state
    }

    deinit {
        stop()
    }

    /// Changes what happens on subsequent connections.
    public func setBehavior(_ behavior: Behavior) {
        state.withLock { $0.behavior = behavior }
    }

    /// Connections accepted so far.
    public var connectionCount: Int {
        state.withLock { $0.connectionCount }
    }

    /// Stops listening and closes open connections. Safe to call more than once.
    public func stop() {
        // cancel() only schedules the close and its handlers run later on the server queue, so it is safe
        // under the lock. (NWConnection is Sendable only from macOS 14, so it can't be returned from withLock.)
        state.withLock { state in
            state.isStopped = true
            state.openConnections.values.forEach { $0.cancel() }
            state.openConnections = [:]
        }
        listener.cancel()
    }

    /// Starts `listener` and returns its port once it is ready.
    private static func start(_ listener: NWListener, queue: DispatchQueue) async throws -> UInt16 {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { listenerState in
                let result: Result<UInt16, any Error>
                switch listenerState {
                case .ready:
                    result = listener.port.map { .success($0.rawValue) } ?? .failure(NWError.posix(.EADDRNOTAVAIL))
                case .waiting(let error), .failed(let error):
                    listener.cancel()
                    result = .failure(error)
                case .cancelled:
                    result = .failure(NWError.posix(.ECANCELED))
                default:
                    return
                }
                let isFirst = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if isFirst {
                    continuation.resume(with: result)
                }
            }
            listener.start(queue: queue)
        }
    }

    private static func accept(
        _ connection: NWConnection,
        state: OSAllocatedUnfairLock<State>,
        queue: DispatchQueue
    ) {
        let id = ObjectIdentifier(connection)
        connection.stateUpdateHandler = { connectionState in
            switch connectionState {
            case .waiting, .failed:
                connection.cancel()
            case .cancelled:
                state.withLock { _ = $0.openConnections.removeValue(forKey: id) }
            default:
                break
            }
        }
        // Started before it is registered, so a concurrent stop() can only cancel a started connection.
        connection.start(queue: queue)
        let behavior = state.withLock { state -> Behavior? in
            guard !state.isStopped else { return nil }
            state.connectionCount += 1
            state.openConnections[id] = connection
            return state.behavior
        }
        guard let behavior else {
            connection.cancel()
            return
        }
        switch behavior {
        case .packet(let title):
            sendAndClose(VitaPacket.encode(title), on: connection)
        case .raw(let bytes):
            sendAndClose(bytes, on: connection)
        case .chunked(let bytes, let chunkSize, let delay):
            let size = max(chunkSize, 1)
            let chunks = stride(from: 0, to: bytes.count, by: size).map {
                Array(bytes[$0..<min($0 + size, bytes.count)])
            }
            sendChunks(chunks[...], delay: delay, on: connection, queue: queue)
        case .silent:
            break
        case .closeImmediately:
            sendAndClose([], on: connection)
        }
    }

    /// Sends `bytes` followed by FIN, then closes once the stack has taken the data.
    private static func sendAndClose(_ bytes: [UInt8], on connection: NWConnection) {
        connection.send(
            content: bytes.isEmpty ? nil : Data(bytes),
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    private static func sendChunks(
        _ chunks: ArraySlice<[UInt8]>,
        delay: Duration,
        on connection: NWConnection,
        queue: DispatchQueue
    ) {
        guard let chunk = chunks.first, chunks.count > 1 else {
            sendAndClose(chunks.first ?? [], on: connection)
            return
        }
        connection.send(content: Data(chunk), completion: .contentProcessed { error in
            guard error == nil else { return }  // cancelled by stop()
            let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
            queue.asyncAfter(deadline: .now() + seconds) {
                sendChunks(chunks.dropFirst(), delay: delay, on: connection, queue: queue)
            }
        })
    }
}

import Foundation
import Network
import os

/// Fetches the Vita's current title. `VitaClient` is the real implementation; tests substitute fakes.
public protocol VitaTitleFetching: Sendable {
    /// Opens one TCP connection to `host` (an IPv4 dotted quad), reads one packet, and closes it.
    /// - Throws: `VitaConnectionError`, or `CancellationError` if the calling task is cancelled.
    func fetchTitle(from host: String) async throws -> VitaTitle
}

/// Polls the VitaPresence plugin over TCP with Network.framework.
///
/// One call is one connection: connect (bounded by `connectTimeout`), write nothing, read until EOF or
/// `VitaPacket.maximumReadLength` bytes (bounded by `readTimeout`), then close gracefully with `cancel()`.
///
/// `NWConnection` reports refused or unreachable hosts and Local Network denial as `.waiting` rather than
/// `.failed`, and retries forever. This client treats `.waiting` as an immediate failure, checking
/// `currentPath?.unsatisfiedReason == .localNetworkDenied` first, and maps POSIX errors:
/// ECONNREFUSED → `.refused`, ETIMEDOUT → `.timedOut`, EHOSTUNREACH/EHOSTDOWN/ENETUNREACH/ENETDOWN →
/// `.unreachable`. It resumes its continuation exactly once, even when cancellation, timeout and connection
/// callbacks race.
public struct VitaClient: VitaTitleFetching {
    public var port: UInt16
    public var connectTimeout: Duration
    public var readTimeout: Duration

    public init(
        port: UInt16 = VitaPacket.port,
        connectTimeout: Duration = .seconds(3),
        readTimeout: Duration = .seconds(5)
    ) {
        self.port = port
        self.connectTimeout = connectTimeout
        self.readTimeout = readTimeout
    }

    public func fetchTitle(from host: String) async throws -> VitaTitle {
        guard IPv4.parse(host) != nil, let address = IPv4Address(host) else {
            throw VitaConnectionError.unresolvedAddress("“\(host)” isn't a valid IPv4 address")
        }
        try Task.checkCancellation()
        let fetch = Fetch(
            endpoint: .hostPort(host: .ipv4(address), port: NWEndpoint.Port(integerLiteral: port)),
            connectTimeout: connectTimeout,
            readTimeout: readTimeout
        )
        return try await fetch.run()
    }

    /// Maps a connection failure. Local Network denial comes first: it surfaces with an unrelated POSIX error.
    static func connectionError(
        for error: NWError,
        unsatisfiedReason: NWPath.UnsatisfiedReason?
    ) -> VitaConnectionError {
        if unsatisfiedReason == .localNetworkDenied { return .localNetworkDenied }
        guard case .posix(let code) = error else { return .other(error.debugDescription) }
        let description = String(cString: strerror(code.rawValue))
        switch code {
        case .ECONNREFUSED: return .refused
        case .ETIMEDOUT: return .timedOut
        case .EHOSTUNREACH, .EHOSTDOWN, .ENETUNREACH, .ENETDOWN: return .unreachable(description)
        default: return .other(description)
        }
    }

    /// The title in the bytes received before EOF or the read cap.
    static func title(from bytes: [UInt8]) -> Result<VitaTitle, VitaConnectionError> {
        do throws(VitaPacketError) {
            return .success(try VitaPacket.parse(bytes))
        } catch .tooShort(let byteCount) {
            return .failure(.incompletePacket(byteCount: byteCount))
        } catch {
            return .failure(.invalidPacket(error))
        }
    }
}

/// One `fetchTitle` call. Connection callbacks and timers run on `queue`, while task cancellation can arrive
/// on any thread, so all mutable state lives behind `lock`.
private final class Fetch: Sendable {
    private enum Phase {
        case idle, connecting, reading, finished
    }

    private struct State {
        var phase = Phase.idle
        var continuation: CheckedContinuation<VitaTitle, any Error>?
        var received: [UInt8] = []
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "io.github.aegiosot.VitaPresence.VitaClient")
    private let connectTimeout: Duration
    private let readTimeout: Duration
    private let lock = OSAllocatedUnfairLock(initialState: State())

    init(endpoint: NWEndpoint, connectTimeout: Duration, readTimeout: Duration) {
        let tcp = NWProtocolTCP.Options()
        // Whole seconds only; the connect timer below enforces the exact value.
        tcp.connectionTimeout = Int(min(max(connectTimeout.timeInterval.rounded(.up), 1), Double(Int32.max)))
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.preferNoProxies = true
        connection = NWConnection(to: endpoint, using: parameters)
        self.connectTimeout = connectTimeout
        self.readTimeout = readTimeout
    }

    func run() async throws -> VitaTitle {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { start($0) }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    private func start(_ continuation: CheckedContinuation<VitaTitle, any Error>) {
        let cancelled = lock.withLock { state in
            guard state.phase == .idle else { return true }
            state.phase = .connecting
            state.continuation = continuation
            return false
        }
        if cancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        // `finish` cancels on `queue` too, so a connection is never started after it was cancelled.
        queue.async { [self] in
            guard lock.withLock({ $0.phase == .connecting }) else { return }
            connection.stateUpdateHandler = { [self] in handle($0) }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + connectTimeout.timeInterval) { [self] in
                finish(.failure(VitaConnectionError.timedOut), ifStillIn: .connecting)
            }
        }
    }

    private func handle(_ connectionState: NWConnection.State) {
        switch connectionState {
        case .ready:
            let connected = lock.withLock { state in
                guard state.phase == .connecting else { return false }
                state.phase = .reading
                return true
            }
            guard connected else { return }
            queue.asyncAfter(deadline: .now() + readTimeout.timeInterval) { [self] in
                finish(.failure(VitaConnectionError.timedOut))
            }
            receive()
        case .waiting(let error), .failed(let error):
            // `.waiting` would retry forever; one poll is one attempt.
            fail(with: error)
        default:
            break
        }
    }

    private func receive() {
        let remaining = VitaPacket.maximumReadLength - lock.withLock { $0.received.count }
        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [self] data, _, isComplete, error in
            // After `finish`, completions are stale: cancel() completes a pending receive with 0 bytes and
            // isComplete before `.cancelled` arrives, which must not be mistaken for a short packet.
            let received = lock.withLock { state -> [UInt8]? in
                guard state.phase == .reading else { return nil }
                if let data { state.received.append(contentsOf: data) }
                return state.received
            }
            guard let received else { return }
            if let error {
                fail(with: error)
            } else if isComplete || received.count >= VitaPacket.maximumReadLength {
                finish(VitaClient.title(from: received).mapError { $0 })
            } else {
                receive()
            }
        }
    }

    private func fail(with error: NWError) {
        let reason = connection.currentPath?.unsatisfiedReason
        finish(.failure(VitaClient.connectionError(for: error, unsatisfiedReason: reason)))
    }

    /// Resumes the caller with `result` and closes the connection gracefully, the first time only. With
    /// `phase`, it does nothing unless the fetch is still in that phase.
    private func finish(_ result: Result<VitaTitle, any Error>, ifStillIn phase: Phase? = nil) {
        let continuation = lock.withLock { state -> CheckedContinuation<VitaTitle, any Error>? in
            guard state.phase != .finished, phase == nil || state.phase == phase else { return nil }
            state.phase = .finished
            defer { state.continuation = nil }
            return state.continuation
        }
        guard let continuation else { return }
        queue.async { [connection] in connection.cancel() }
        continuation.resume(with: result)
    }
}

private extension Duration {
    /// The duration in seconds, for Dispatch and Network APIs.
    var timeInterval: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

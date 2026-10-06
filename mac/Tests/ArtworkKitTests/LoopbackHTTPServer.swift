import Foundation
import Network
import os

/// A minimal HTTP/1.1 server on `127.0.0.1` for `URLSessionHTTPClient` tests. Each connection carries one
/// request, which `respond` answers (or leaves unanswered when it returns `nil`); then the connection closes.
final class LoopbackHTTPServer: Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        /// Header names lowercased.
        var headers: [String: String]
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
    }

    private struct State {
        var requests: [Request] = []
        var connections: [ObjectIdentifier: NWConnection] = [:]
        var isStopped = false
    }

    let port: UInt16
    private let listener: NWListener
    private let state: OSAllocatedUnfairLock<State>

    /// Starts listening on an ephemeral loopback port. Returns once the listener is ready.
    init(respond: @escaping @Sendable (Request) -> Response?) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "LoopbackHTTPServer")
        let state = OSAllocatedUnfairLock(initialState: State())
        listener.newConnectionHandler = { connection in
            Self.serve(connection, state: state, queue: queue, respond: respond)
        }
        port = try await Self.start(listener, queue: queue)
        self.listener = listener
        self.state = state
    }

    deinit {
        stop()
    }

    /// `http://127.0.0.1:<port><path>`.
    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    /// Requests received so far, in order.
    var requests: [Request] {
        state.withLock { $0.requests }
    }

    /// Stops listening and closes open connections. Safe to call more than once.
    func stop() {
        state.withLock { state in
            state.isStopped = true
            state.connections.values.forEach { $0.cancel() }
            state.connections = [:]
        }
        listener.cancel()
    }

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
                if isFirst { continuation.resume(with: result) }
            }
            listener.start(queue: queue)
        }
    }

    private static func serve(
        _ connection: NWConnection,
        state: OSAllocatedUnfairLock<State>,
        queue: DispatchQueue,
        respond: @escaping @Sendable (Request) -> Response?
    ) {
        let id = ObjectIdentifier(connection)
        connection.stateUpdateHandler = { connectionState in
            switch connectionState {
            case .waiting, .failed:
                connection.cancel()
            case .cancelled:
                state.withLock { _ = $0.connections.removeValue(forKey: id) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        let isStopped = state.withLock { state in
            if !state.isStopped { state.connections[id] = connection }
            return state.isStopped
        }
        guard !isStopped else {
            connection.cancel()
            return
        }
        readHead(from: connection, buffer: Data()) { head in
            guard let request = parse(head) else {
                connection.cancel()
                return
            }
            state.withLock { $0.requests.append(request) }
            guard let response = respond(request) else { return }
            connection.send(
                content: encode(response, includingBody: request.method != "HEAD"),
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
    }

    /// Reads until the blank line that ends the request head.
    private static func readHead(
        from connection: NWConnection,
        buffer: Data,
        then handle: @escaping @Sendable (Data) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            let buffer = buffer + (data ?? Data())
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                handle(buffer[..<end.lowerBound])
            } else if error == nil, !isComplete {
                readHead(from: connection, buffer: buffer, then: handle)
            } else {
                connection.cancel()
            }
        }
    }

    private static func parse(_ head: Data) -> Request? {
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count == 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        return Request(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers)
    }

    private static func encode(_ response: Response, includingBody: Bool) -> Data {
        var head = "HTTP/1.1 \(response.status) \(HTTPURLResponse.localizedString(forStatusCode: response.status))\r\n"
        for (name, value) in response.headers {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + (includingBody ? response.body : Data())
    }
}

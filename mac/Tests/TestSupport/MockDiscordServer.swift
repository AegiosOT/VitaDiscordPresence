import DiscordIPC
import Foundation
import os

/// A Unix-domain-socket server that speaks Discord's IPC framing, for tests.
///
/// It creates a short private directory under `/tmp` (socket paths must stay under 104 bytes) and listens
/// on `<directory>/discord-ipc-0`. Point a client at it with
/// `DiscordIPCClient(socketPaths: { [server.socketPath] })`, or a child process with
/// `XDG_RUNTIME_DIR=<directory>`.
///
/// Like Discord, it answers a client's PING with a PONG and a client's CLOSE with
/// `{"code":1000,"message":"client disconnect"}` before closing that connection. It is stopped on deinit.
public final class MockDiscordServer: Sendable {
    /// How to answer the HANDSHAKE.
    public enum HandshakeResponse: Sendable, Equatable {
        /// Send the READY dispatch for this user.
        case ready(DiscordUser)
        /// Send CLOSE with this code and message, then close the socket (4000 = invalid client ID).
        case close(code: Int, message: String)
        /// Never answer (exercises READY timeouts).
        case ignore
    }

    /// How to answer FRAME commands such as SET_ACTIVITY.
    public enum CommandResponse: Sendable, Equatable {
        /// Reply `{"cmd":<cmd>,"evt":null,"nonce":<nonce>,"data":<args.activity or null>}`.
        case success
        /// Reply `{"cmd":<cmd>,"evt":"ERROR","nonce":<nonce>,"data":{"code":…,"message":…}}`.
        case error(code: Int, message: String)
        /// Never reply (exercises reply timeouts).
        case ignore
    }

    /// The directory to use as `XDG_RUNTIME_DIR`.
    public let directory: String
    /// `<directory>/discord-ipc-0`.
    public let socketPath: String

    private let core: Core

    /// Starts listening. Returns once the socket is bound and listening.
    public init(
        handshake: HandshakeResponse = .ready(DiscordUser(id: "1", username: "tester", globalName: "Tester")),
        commands: CommandResponse = .success
    ) throws {
        var template = Array("/tmp/vp-XXXXXX".utf8CString)
        guard mkdtemp(&template) != nil else { throw POSIXError.fromErrno() }
        let directory = String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let socketPath = directory + "/discord-ipc-0"
        do {
            core = try Core(socketPath: socketPath, handshake: handshake, commands: commands)
        } catch {
            rmdir(directory)
            throw error
        }
        self.directory = directory
        self.socketPath = socketPath
        core.startAccepting()
    }

    deinit {
        stop()
    }

    /// Changes how later handshakes are answered.
    public func setHandshakeResponse(_ response: HandshakeResponse) {
        core.state.withLock { $0.handshakeResponse = response }
    }

    /// Changes how later commands are answered.
    public func setCommandResponse(_ response: CommandResponse) {
        core.state.withLock { $0.commandResponse = response }
    }

    /// Raw JSON payloads of every HANDSHAKE received, in order.
    public var handshakes: [Data] {
        payloads(of: .handshake)
    }

    /// Raw JSON payloads of every FRAME received, in order.
    public var commands: [Data] {
        payloads(of: .frame)
    }

    /// Payloads of every PONG received, in order.
    public var pongs: [Data] {
        payloads(of: .pong)
    }

    /// Every frame received from any client (all opcodes, CLOSE included), in the order they were read.
    public var receivedFrames: [DiscordFrame] {
        core.state.withLock { $0.frames }
    }

    /// Number of client connections accepted so far.
    public var connectionCount: Int {
        core.state.withLock { $0.connectionCount }
    }

    /// Number of client connections currently open; it drops once either side closes a connection.
    public var openConnectionCount: Int {
        core.state.withLock { $0.clients.count }
    }

    /// Sends a PING with `payload` to every connected client.
    public func sendPing(_ payload: Data) {
        core.write(DiscordFrame(opcode: .ping, payload: payload).encoded())
    }

    /// Writes `bytes` unchanged to every connected client (exercises malformed or unexpected input).
    public func sendRaw(_ bytes: Data) {
        core.write(bytes)
    }

    /// Closes all client connections without a CLOSE frame, as if Discord quit; keeps listening.
    public func dropClients() {
        core.state.withLock { state in
            for client in state.clients { shutdown(client, SHUT_RDWR) }
        }
    }

    /// Stops listening, closes connections, and removes the socket and directory. Safe to call more than once.
    public func stop() {
        let wasRunning = core.state.withLock { state in
            guard !state.isStopped else { return false }
            state.isStopped = true
            for client in state.clients { shutdown(client, SHUT_RDWR) }
            return true
        }
        guard wasRunning else { return }
        unlink(socketPath)
        rmdir(directory)
    }

    private func payloads(of opcode: DiscordOpcode) -> [Data] {
        core.state.withLock { state in state.frames.filter { $0.opcode == opcode }.map(\.payload) }
    }
}

/// The listening socket and its threads. The threads hold this object rather than the server, so releasing
/// the server stops it.
///
/// Descriptor ownership: the accept thread owns the listening socket, and each client's thread owns that
/// client's socket and is the only one to close it, under the lock. Everything else touches a client socket
/// only under the lock and only while it is registered, so it never reaches a closed or reused descriptor.
private final class Core: Sendable {
    struct State: Sendable {
        var handshakeResponse: MockDiscordServer.HandshakeResponse
        var commandResponse: MockDiscordServer.CommandResponse
        var frames: [DiscordFrame] = []
        var connectionCount = 0
        var clients: Set<Int32> = []
        var isStopped = false
    }

    let state: OSAllocatedUnfairLock<State>
    private let listener: Int32

    init(
        socketPath: String,
        handshake: MockDiscordServer.HandshakeResponse,
        commands: MockDiscordServer.CommandResponse
    ) throws {
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError.fromErrno() }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(listener)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 16) == 0 else {
            let error = POSIXError.fromErrno()
            close(listener)
            throw error
        }
        self.listener = listener
        state = OSAllocatedUnfairLock(initialState: State(handshakeResponse: handshake, commandResponse: commands))
    }

    func startAccepting() {
        Thread.detachNewThread { self.acceptLoop() }
    }

    /// Writes `data` to `client`, or to every connected client when `client` is `nil`.
    func write(_ data: Data, to client: Int32? = nil) {
        state.withLock { state in
            for descriptor in state.clients where client == nil || client == descriptor {
                Self.writeAll(data, to: descriptor)
            }
        }
    }

    /// Accepts clients until the server stops. Polls with a short timeout so it notices `stop()` without
    /// another thread having to close the listening socket under it.
    private func acceptLoop() {
        var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        while !state.withLock({ $0.isStopped }) {
            guard poll(&descriptor, 1, 50) > 0 else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let isAccepted = state.withLock { state in
                guard !state.isStopped else { return false }
                state.connectionCount += 1
                state.clients.insert(client)
                return true
            }
            guard isAccepted else {
                close(client)
                break
            }
            Thread.detachNewThread { self.serve(client) }
        }
        close(listener)
    }

    /// Reads and answers one client until it disconnects, misbehaves, or is dropped.
    private func serve(_ client: Int32) {
        var decoder = DiscordFrameDecoder()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        reading: while true {
            let count = read(client, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            decoder.append(Data(buffer[..<count]))
            do {
                while let frame = try decoder.nextFrame() {
                    guard respond(to: frame, from: client) else { break reading }
                }
            } catch {
                break
            }
        }
        state.withLock { state in
            state.clients.remove(client)
            close(client)
        }
    }

    /// Records `frame` and answers it. Returns `false` when the connection should be closed.
    private func respond(to frame: DiscordFrame, from client: Int32) -> Bool {
        let (handshake, command) = state.withLock { state in
            state.frames.append(frame)
            return (state.handshakeResponse, state.commandResponse)
        }
        switch frame.opcode {
        case .handshake:
            switch handshake {
            case .ready(let user):
                write(Self.readyFrame(for: user).encoded(), to: client)
            case .close(let code, let message):
                write(Self.closeFrame(code: code, message: message).encoded(), to: client)
                return false
            case .ignore:
                break
            }
        case .frame:
            if let reply = Self.reply(to: frame.payload, with: command) {
                write(reply.encoded(), to: client)
            }
        case .ping:
            write(DiscordFrame(opcode: .pong, payload: frame.payload).encoded(), to: client)
        case .pong:
            break
        case .close:
            write(Self.closeFrame(code: 1000, message: "client disconnect").encoded(), to: client)
            return false
        }
        return true
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    /// The READY dispatch, shaped like Discord's.
    private static func readyFrame(for user: DiscordUser) -> DiscordFrame {
        let userObject: [String: Any] = [
            "id": user.id,
            "username": user.username,
            "discriminator": "0",
            "global_name": user.globalName.map { $0 as Any } ?? NSNull(),
            "avatar": NSNull(),
        ]
        let config: [String: Any] = [
            "cdn_host": "cdn.discordapp.com",
            "api_endpoint": "//discord.com/api",
            "environment": "production",
        ]
        let data: [String: Any] = ["v": 1, "config": config, "user": userObject]
        return jsonFrame(.frame, ["cmd": "DISPATCH", "evt": "READY", "nonce": NSNull(), "data": data])
    }

    private static func closeFrame(code: Int, message: String) -> DiscordFrame {
        jsonFrame(.close, ["code": code, "message": message])
    }

    /// The reply to a command, or `nil` when the payload isn't a JSON object or commands are ignored.
    private static func reply(to payload: Data, with response: MockDiscordServer.CommandResponse) -> DiscordFrame? {
        guard let command = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { return nil }
        let cmd = command["cmd"] ?? NSNull()
        let nonce = command["nonce"] ?? NSNull()
        switch response {
        case .success:
            let activity = (command["args"] as? [String: Any])?["activity"] ?? NSNull()
            return jsonFrame(.frame, ["cmd": cmd, "evt": NSNull(), "nonce": nonce, "data": activity])
        case .error(let code, let message):
            let data: [String: Any] = ["code": code, "message": message]
            return jsonFrame(.frame, ["cmd": cmd, "evt": "ERROR", "nonce": nonce, "data": data])
        case .ignore:
            return nil
        }
    }

    /// Every object passed here is built from JSON-compatible values, so serialization can't fail.
    private static func jsonFrame(_ opcode: DiscordOpcode, _ object: [String: Any]) -> DiscordFrame {
        DiscordFrame(opcode: opcode, payload: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }
}

private extension POSIXError {
    /// The error for the current `errno`.
    static func fromErrno() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

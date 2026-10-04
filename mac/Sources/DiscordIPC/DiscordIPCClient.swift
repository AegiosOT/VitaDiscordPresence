import Foundation
import Network

/// Something that can show an activity on Discord. `DiscordIPCClient` is the real implementation; tests
/// substitute fakes.
public protocol DiscordPresenceSink: Sendable {
    /// Connects if needed, handshakes, and waits for READY. Returns the logged-in user.
    ///
    /// When already connected with the same `clientID`, it returns the cached user without reconnecting. With
    /// a different `clientID`, it disconnects first.
    /// - Throws: `DiscordIPCError` (`.discordNotRunning`, `.invalidClientID`, `.timedOut`, …).
    func connect(clientID: String) async throws -> DiscordUser

    /// Sends SET_ACTIVITY (`nil` clears the activity) and waits for Discord's reply with the matching nonce.
    /// - Throws: `DiscordIPCError.rpcError` when Discord rejects the payload (the connection stays usable),
    ///   `.notConnected` when not connected, `.timedOut` or `.io` when the connection broke (it is closed).
    func setActivity(_ activity: DiscordActivity?) async throws

    /// Clears the activity if connected (best effort), sends CLOSE, and closes the socket. Never throws.
    func disconnect() async

    /// `true` while the socket is open and READY has been received.
    var isConnected: Bool { get async }
}

/// A native client for Discord's local IPC socket (`discord-ipc-N`), built on Network.framework
/// (`NWEndpoint.unix(path:)`).
///
/// Behaviour:
/// - **connect:** tries each path from `socketPaths()` in order with a fresh connection. ENOENT and
///   ECONNREFUSED (which `NWConnection` reports as `.waiting`) mean "try the next path"; if none connects it
///   throws `.discordNotRunning`. It then sends HANDSHAKE `{"v":1,"client_id":…}` and waits up to `timeout`
///   for the frame with `cmd == "DISPATCH"` and `evt == "READY"`. A CLOSE with code 4000 throws
///   `.invalidClientID`.
/// - **reading:** one read loop per connection decodes frames with `DiscordFrameDecoder`. It answers PING
///   with a PONG carrying the identical payload and routes replies to waiting commands by `nonce`. On CLOSE,
///   EOF or an error it marks the client disconnected and fails pending commands.
/// - **setActivity:** `{"cmd":"SET_ACTIVITY","args":{"pid":<processID>,"activity":…},"nonce":<UUID>}`. When
///   clearing, it omits `activity`. The activity is sent `sanitized()`.
/// - **writes:** every frame goes out in a single `send`.
/// - **overlapping calls:** a `connect` that can't reuse a READY connection replaces whatever connection
///   exists or is being set up, and `disconnect` aborts a `connect` in progress (it throws `.notConnected`).
///   Cancelling the task of `connect` aborts it; cancelling `setActivity` only stops waiting for the reply.
public actor DiscordIPCClient: DiscordPresenceSink {
    private let socketPaths: @Sendable () -> [String]
    private let timeout: Duration
    private let processID: Int32
    /// Network.framework callbacks and timeouts of every connection run here.
    private let queue = DispatchQueue(label: "io.github.aegiosot.VitaPresence.DiscordIPC")

    /// How long each candidate socket gets to accept the connection.
    private static let socketTimeout: Duration = .seconds(1)
    /// Cap for each farewell step of `disconnect()`: the clearing SET_ACTIVITY and the CLOSE frame.
    private static let farewellTimeout: Duration = .seconds(1)
    /// The CLOSE code for an application ID that doesn't exist.
    private static let invalidClientIDCode = 4000
    /// Reported when the socket ends without a CLOSE frame (WebSocket's "abnormal closure").
    private static let abnormalClosureCode = 1006

    /// Bumped by every connection attempt and every teardown. Read loops, timers and send completions carry
    /// the value they started with, so nothing that belongs to an older connection affects a newer one.
    private var generation: UInt64 = 0
    /// The client ID of the connection being set up or in use; `nil` when idle.
    private var clientID: String?
    private var connection: NWConnection?
    /// The user from READY, while the connection is usable.
    private var user: DiscordUser?
    private var decoder = DiscordFrameDecoder()
    private var readyWaiter: Waiter<DiscordUser>?
    private var pendingCommands: [String: Waiter<Void>] = [:]

    public init(
        socketPaths: @escaping @Sendable () -> [String] = { DiscordIPCPath.candidates() },
        timeout: Duration = .seconds(10),
        processID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        self.socketPaths = socketPaths
        self.timeout = timeout
        self.processID = processID
    }

    /// A client released while connected still closes its socket, which makes Discord drop its activity.
    deinit {
        connection?.cancel()
    }

    public func connect(clientID: String) async throws -> DiscordUser {
        while self.clientID != nil {
            if self.clientID == clientID, let user { return user }
            await disconnect()
        }
        generation &+= 1
        let generation = generation
        self.clientID = clientID
        do {
            let connection = try await openSocket(generation: generation)
            guard self.generation == generation else {
                connection.cancel()
                throw DiscordIPCError.notConnected
            }
            self.connection = connection
            startReading(connection, generation: generation)
            return try await handshake(clientID: clientID, on: connection, generation: generation)
        } catch {
            if self.generation == generation { tearDown(error) }
            throw error
        }
    }

    public func setActivity(_ activity: DiscordActivity?) async throws {
        guard user != nil, let connection else { throw DiscordIPCError.notConnected }
        try await sendActivity(activity?.sanitized(), on: connection, timeout: timeout)
    }

    public func disconnect() async {
        guard clientID != nil else { return }
        let generation = generation
        if user != nil, let connection {
            user = nil // Unusable from now on; the farewell's reply is still routed.
            let farewellTimeout = min(timeout, Self.farewellTimeout)
            try? await sendActivity(nil, on: connection, timeout: farewellTimeout, closesOnTimeout: false)
            if self.generation == generation {
                let close = DiscordFrame(opcode: .close, payload: Data("{}".utf8))
                await connection.sendAndWait(close.encoded(), queue: queue, timeout: farewellTimeout)
            }
        }
        if self.generation == generation { tearDown(DiscordIPCError.notConnected) }
    }

    public var isConnected: Bool {
        user != nil
    }

    // MARK: - Connecting

    /// The first candidate socket that accepts a connection.
    private func openSocket(generation: UInt64) async throws -> NWConnection {
        for path in socketPaths() where DiscordIPCPath.fitsSocketAddress(path) {
            guard self.generation == generation else { throw DiscordIPCError.notConnected }
            try Task.checkCancellation()
            let connection = NWConnection(to: .unix(path: path), using: .tcp)
            if await connection.startAndWaitUntilReady(on: queue, timeout: Self.socketTimeout) {
                return connection
            }
            connection.cancel()
        }
        try Task.checkCancellation()
        throw DiscordIPCError.discordNotRunning
    }

    /// Sends HANDSHAKE and waits up to `timeout` for READY.
    private func handshake(clientID: String, on connection: NWConnection, generation: UInt64) async throws
        -> DiscordUser
    {
        let frame = try Self.frame(.handshake, HandshakePayload(clientID: clientID))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { return continuation.resume(throwing: CancellationError()) }
                let timer = Task { [weak self, timeout] in
                    guard (try? await Task.sleep(for: timeout)) != nil else { return }
                    await self?.abandonHandshake(generation: generation, error: DiscordIPCError.timedOut)
                }
                readyWaiter = Waiter(continuation: continuation, timer: timer)
                write(frame, on: connection, generation: generation)
            }
        } onCancel: {
            Task { await self.abandonHandshake(generation: generation, error: CancellationError()) }
        }
    }

    /// Gives up on the handshake of `generation` if it is still waiting for READY.
    private func abandonHandshake(generation: UInt64, error: any Error) {
        guard self.generation == generation, readyWaiter != nil else { return }
        tearDown(error)
    }

    // MARK: - Commands

    /// Sends SET_ACTIVITY and waits up to `timeout` for the reply with the same nonce. A timeout throws
    /// `.timedOut` and, when `closesOnTimeout`, closes the connection as broken.
    private func sendActivity(
        _ activity: DiscordActivity?,
        on connection: NWConnection,
        timeout: Duration,
        closesOnTimeout: Bool = true
    ) async throws {
        let nonce = UUID().uuidString
        let command = SetActivityCommand(args: .init(pid: processID, activity: activity), nonce: nonce)
        let frame = try Self.frame(.frame, command)
        let generation = generation
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else { return continuation.resume(throwing: CancellationError()) }
                let timer = Task { [weak self] in
                    guard (try? await Task.sleep(for: timeout)) != nil else { return }
                    await self?.commandTimedOut(nonce: nonce, generation: generation, closesConnection: closesOnTimeout)
                }
                pendingCommands[nonce] = Waiter(continuation: continuation, timer: timer)
                write(frame, on: connection, generation: generation)
            }
        } onCancel: {
            Task { await self.cancelCommand(nonce: nonce) }
        }
    }

    private func commandTimedOut(nonce: String, generation: UInt64, closesConnection: Bool) {
        guard self.generation == generation, let waiter = pendingCommands[nonce] else { return }
        if closesConnection {
            tearDown(DiscordIPCError.timedOut)
        } else {
            pendingCommands[nonce] = nil
            waiter.fail(DiscordIPCError.timedOut)
        }
    }

    /// Stops waiting for the reply to `nonce`; the connection stays open.
    private func cancelCommand(nonce: String) {
        pendingCommands.removeValue(forKey: nonce)?.fail(CancellationError())
    }

    // MARK: - Reading

    /// Starts the read loop of `connection`. The loop holds the client weakly: a released client cancels its
    /// connection in `deinit`, which completes the pending receive and ends the loop.
    private func startReading(_ connection: NWConnection, generation: UInt64) {
        Task { [weak self] in
            var keepReading = true
            while keepReading {
                let chunk = await connection.receiveChunk()
                keepReading = await self?.process(chunk, generation: generation) ?? false
            }
        }
    }

    /// Handles what the read loop of `generation` received. Returns whether to keep reading.
    private func process(_ chunk: IPCChunk, generation: UInt64) -> Bool {
        guard self.generation == generation else { return false }
        decoder.append(chunk.data)
        do {
            while let frame = try decoder.nextFrame() {
                handle(frame, generation: generation)
                guard self.generation == generation else { return false }
            }
        } catch {
            tearDown(error)
            return false
        }
        if let error = chunk.error {
            tearDown(DiscordIPCError.io(error.debugDescription))
            return false
        }
        if chunk.isComplete {
            tearDown(DiscordIPCError.closedByDiscord(
                code: Self.abnormalClosureCode,
                message: "The socket closed without a CLOSE frame"
            ))
            return false
        }
        return true
    }

    private func handle(_ frame: DiscordFrame, generation: UInt64) {
        switch frame.opcode {
        case .ping:
            if let connection {
                write(DiscordFrame(opcode: .pong, payload: frame.payload), on: connection, generation: generation)
            }
        case .close:
            let close = (try? JSONDecoder().decode(ClosePayload.self, from: frame.payload)) ?? ClosePayload()
            let code = close.code ?? 0
            if readyWaiter != nil, code == Self.invalidClientIDCode {
                tearDown(DiscordIPCError.invalidClientID)
            } else {
                tearDown(DiscordIPCError.closedByDiscord(code: code, message: close.message ?? ""))
            }
        case .frame:
            guard let message = try? JSONDecoder().decode(IncomingMessage.self, from: frame.payload) else {
                return tearDown(DiscordIPCError.protocolViolation("Received a FRAME that isn't a JSON object"))
            }
            route(message)
        case .handshake, .pong:
            break // Only clients send these.
        }
    }

    /// Resolves READY while handshaking, and replies by nonce. Anything else is ignored.
    private func route(_ message: IncomingMessage) {
        if message.cmd == "DISPATCH", message.evt == "READY", let waiter = readyWaiter {
            guard let user = message.data?.user else {
                return tearDown(DiscordIPCError.protocolViolation("READY without a user"))
            }
            readyWaiter = nil
            self.user = user
            waiter.succeed(user)
        } else if let nonce = message.nonce, let waiter = pendingCommands.removeValue(forKey: nonce) {
            if message.evt == "ERROR" {
                waiter.fail(DiscordIPCError.rpcError(
                    code: message.data?.code ?? 0,
                    message: message.data?.message ?? ""
                ))
            } else {
                waiter.succeed(())
            }
        }
    }

    // MARK: - Plumbing

    /// Writes `frame` in a single send. A failed send closes the connection of `generation`.
    private func write(_ frame: DiscordFrame, on connection: NWConnection, generation: UInt64) {
        connection.send(content: frame.encoded(), completion: .contentProcessed { [weak self] error in
            guard let error, let self else { return }
            Task { await self.sendFailed(DiscordIPCError.io(error.debugDescription), generation: generation) }
        })
    }

    private func sendFailed(_ error: DiscordIPCError, generation: UInt64) {
        guard self.generation == generation else { return }
        tearDown(error)
    }

    /// Closes the connection, returns to idle, and fails everything waiting on it with `error`.
    private func tearDown(_ error: any Error) {
        generation &+= 1
        connection?.cancel()
        connection = nil
        clientID = nil
        user = nil
        decoder = DiscordFrameDecoder()
        let readyWaiter = self.readyWaiter
        let commands = pendingCommands.values
        self.readyWaiter = nil
        pendingCommands = [:]
        readyWaiter?.fail(error)
        for command in commands { command.fail(error) }
    }

    private static func frame(_ opcode: DiscordOpcode, _ message: some Encodable) throws(DiscordIPCError)
        -> DiscordFrame
    {
        do {
            return try DiscordFrame(opcode: opcode, json: message)
        } catch {
            throw .protocolViolation("Couldn't encode a message: \(error)")
        }
    }
}

/// A caller waiting for Discord, with the timer that gives up for it. The client removes a waiter from its
/// state before resuming it, so each continuation is resumed exactly once.
private struct Waiter<Value: Sendable> {
    let continuation: CheckedContinuation<Value, any Error>
    let timer: Task<Void, Never>

    func succeed(_ value: Value) {
        timer.cancel()
        continuation.resume(returning: value)
    }

    func fail(_ error: any Error) {
        timer.cancel()
        continuation.resume(throwing: error)
    }
}

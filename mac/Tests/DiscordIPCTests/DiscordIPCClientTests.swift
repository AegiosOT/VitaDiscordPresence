import Foundation
import Testing
import TestSupport
import os
@testable import DiscordIPC

/// The client against `MockDiscordServer`. Every client gets explicit socket paths, so nothing here can
/// reach the real Discord socket.
@Suite struct DiscordIPCClientTests {
    private static let clientID = "1234567890123456789"
    private static let user = DiscordUser(id: "80351110224678912", username: "nelly", globalName: "Nelly")

    // MARK: - Connecting

    @Test func connectHandshakesAndReturnsTheReadyUser() async throws {
        let server = try MockDiscordServer(handshake: .ready(Self.user))
        defer { server.stop() }
        let client = makeClient(server)

        #expect(try await client.connect(clientID: Self.clientID) == Self.user)
        #expect(await client.isConnected)
        let handshake = try jsonObject(try #require(server.handshakes.first))
        #expect(handshake["v"] as? Int == 1)
        #expect(handshake["client_id"] as? String == Self.clientID)
        #expect(Set(handshake.keys) == ["v", "client_id"])
        await client.disconnect()
    }

    @Test func readyUserWithoutAGlobalName() async throws {
        let server = try MockDiscordServer(handshake: .ready(DiscordUser(id: "2", username: "plain")))
        defer { server.stop() }
        let client = makeClient(server)

        let user = try await client.connect(clientID: Self.clientID)
        #expect(user == DiscordUser(id: "2", username: "plain", globalName: nil))
        await client.disconnect()
    }

    @Test func connectingWithTheSameClientIDReusesTheConnection() async throws {
        let server = try MockDiscordServer(handshake: .ready(Self.user))
        defer { server.stop() }
        let client = makeClient(server)

        _ = try await client.connect(clientID: Self.clientID)
        #expect(try await client.connect(clientID: Self.clientID) == Self.user)
        #expect(server.connectionCount == 1)
        #expect(server.handshakes.count == 1)
        await client.disconnect()
    }

    @Test func connectingWithAnotherClientIDReconnects() async throws {
        let server = try MockDiscordServer()
        defer { server.stop() }
        let client = makeClient(server)

        _ = try await client.connect(clientID: "1111111111111111111")
        _ = try await client.connect(clientID: "2222222222222222222")
        #expect(await client.isConnected)
        #expect(server.connectionCount == 2)
        let clientIDs = try server.handshakes.map { try jsonObject($0)["client_id"] as? String }
        #expect(clientIDs == ["1111111111111111111", "2222222222222222222"])
        // The first connection was disconnected properly: its activity cleared, then CLOSE.
        let clear = try jsonObject(try #require(server.commands.first))
        #expect((clear["args"] as? [String: Any]).map { Set($0.keys) } == ["pid"])
        #expect(await eventually { server.receivedFrames.contains { $0.opcode == .close } })
        await client.disconnect()
    }

    @Test func closeCode4000MeansAnInvalidClientID() async throws {
        let server = try MockDiscordServer(handshake: .close(code: 4000, message: "Invalid Client ID"))
        defer { server.stop() }
        let client = makeClient(server)

        await #expect(throws: DiscordIPCError.invalidClientID) {
            _ = try await client.connect(clientID: "1")
        }
        #expect(await !client.isConnected)
    }

    @Test func otherCloseCodesDuringTheHandshakeAreReported() async throws {
        let server = try MockDiscordServer(handshake: .close(code: 4004, message: "Invalid Version: 1"))
        defer { server.stop() }
        let client = makeClient(server)

        await #expect(throws: DiscordIPCError.closedByDiscord(code: 4004, message: "Invalid Version: 1")) {
            _ = try await client.connect(clientID: Self.clientID)
        }
        #expect(await !client.isConnected)
    }

    @Test func connectsOnceTheClientIDIsAccepted() async throws {
        let server = try MockDiscordServer(handshake: .close(code: 4000, message: "Invalid Client ID"))
        defer { server.stop() }
        let client = makeClient(server)

        await #expect(throws: DiscordIPCError.invalidClientID) {
            _ = try await client.connect(clientID: Self.clientID)
        }
        server.setHandshakeResponse(.ready(Self.user))
        #expect(try await client.connect(clientID: Self.clientID) == Self.user)
        #expect(server.connectionCount == 2)
        await client.disconnect()
    }

    @Test func readyTimeout() async throws {
        let server = try MockDiscordServer(handshake: .ignore)
        defer { server.stop() }
        let client = makeClient(server, timeout: .milliseconds(200))

        let start = ContinuousClock.now
        await #expect(throws: DiscordIPCError.timedOut) {
            _ = try await client.connect(clientID: Self.clientID)
        }
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(await !client.isConnected)
        #expect(server.handshakes.count == 1)
        #expect(await eventually { server.openConnectionCount == 0 })
    }

    @Test func socketEndingDuringTheHandshakeIsReported() async throws {
        let server = try MockDiscordServer(handshake: .ignore)
        defer { server.stop() }
        let client = makeClient(server)

        let connecting = Task { try await client.connect(clientID: Self.clientID) }
        #expect(await eventually { server.handshakes.count == 1 })
        server.dropClients()
        let error = await caughtError { _ = try await connecting.value }
        guard case .closedByDiscord(let code, _)? = error as? DiscordIPCError else {
            Issue.record("Expected closedByDiscord, got \(String(describing: error))")
            return
        }
        #expect(code == 1006)
    }

    @Test func readyWithoutAUserIsAProtocolViolation() async throws {
        let server = try MockDiscordServer(handshake: .ignore)
        defer { server.stop() }
        let client = makeClient(server)

        let connecting = Task { try await client.connect(clientID: Self.clientID) }
        #expect(await eventually { server.handshakes.count == 1 })
        server.sendRaw(try jsonFrame(.frame, ["cmd": "DISPATCH", "evt": "READY", "nonce": NSNull(), "data": ["v": 1]])
            .encoded())
        let error = await caughtError { _ = try await connecting.value }
        #expect(isProtocolViolation(error))
        #expect(await !client.isConnected)
        #expect(await eventually { server.openConnectionCount == 0 })
    }

    @Test func onlyTheReadyDispatchCompletesTheHandshake() async throws {
        let server = try MockDiscordServer(handshake: .ignore)
        defer { server.stop() }
        let client = makeClient(server)

        let connecting = Task { try await client.connect(clientID: Self.clientID) }
        #expect(await eventually { server.handshakes.count == 1 })
        let impostor: [String: Any] = ["user": ["id": "9", "username": "impostor"]]
        let readyUser: [String: Any] = ["id": Self.user.id, "username": Self.user.username, "global_name": "Nelly"]
        let ready: [String: Any] = ["v": 1, "user": readyUser]
        let frames = [
            try jsonFrame(.frame, ["cmd": "SET_ACTIVITY", "evt": "READY", "nonce": NSNull(), "data": impostor]),
            try jsonFrame(.frame, ["cmd": "DISPATCH", "evt": "ACTIVITY_JOIN", "nonce": NSNull(), "data": impostor]),
            try jsonFrame(.frame, ["cmd": "DISPATCH", "evt": "READY", "nonce": NSNull(), "data": ready]),
        ]
        server.sendRaw(frames.map { $0.encoded() }.reduce(Data(), +))
        #expect(try await connecting.value == Self.user)
        await client.disconnect()
    }

    @Test func noCandidateSocketMeansDiscordIsNotRunning() async throws {
        let client = DiscordIPCClient(socketPaths: { [] }, timeout: .seconds(1))
        await #expect(throws: DiscordIPCError.discordNotRunning) {
            _ = try await client.connect(clientID: Self.clientID)
        }
    }

    @Test func unusableSocketsMeanDiscordIsNotRunning() async throws {
        let server = try MockDiscordServer()
        defer { server.stop() }
        let unusable = try UnusableSockets(in: server.directory)
        defer { unusable.remove() }
        let client = DiscordIPCClient(socketPaths: { unusable.paths }, timeout: .seconds(1))

        await #expect(throws: DiscordIPCError.discordNotRunning) {
            _ = try await client.connect(clientID: Self.clientID)
        }
        #expect(server.connectionCount == 0)
    }

    @Test func skipsUnusableSocketsAndConnectsToTheNextOne() async throws {
        let server = try MockDiscordServer(handshake: .ready(Self.user))
        defer { server.stop() }
        let unusable = try UnusableSockets(in: server.directory)
        defer { unusable.remove() }
        let client = DiscordIPCClient(socketPaths: { unusable.paths + [server.socketPath] }, timeout: .seconds(5))

        #expect(try await client.connect(clientID: Self.clientID) == Self.user)
        #expect(server.connectionCount == 1)
        await client.disconnect()
    }

    @Test func everyConnectRescansTheCandidates() async throws {
        let server = try MockDiscordServer()
        defer { server.stop() }
        let scans = OSAllocatedUnfairLock(initialState: 0)
        let client = DiscordIPCClient(socketPaths: {
            scans.withLock { $0 += 1 }
            return [server.socketPath]
        })

        _ = try await client.connect(clientID: Self.clientID)
        server.dropClients()
        #expect(await eventually { await !client.isConnected })
        _ = try await client.connect(clientID: Self.clientID)
        #expect(scans.withLock { $0 } == 2)
        await client.disconnect()
    }

    @Test func disconnectAbortsAConnectInProgress() async throws {
        let server = try MockDiscordServer(handshake: .ignore)
        defer { server.stop() }
        let client = makeClient(server, timeout: .seconds(30))

        let connecting = Task { try await client.connect(clientID: Self.clientID) }
        #expect(await eventually { server.handshakes.count == 1 })
        let start = ContinuousClock.now
        await client.disconnect()
        await #expect(throws: DiscordIPCError.notConnected) {
            _ = try await connecting.value
        }
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(await !client.isConnected)
        #expect(await eventually { server.openConnectionCount == 0 })
    }

    @Test func cancellingConnectAbortsIt() async throws {
        let server = try MockDiscordServer(handshake: .ignore)
        defer { server.stop() }
        let client = makeClient(server, timeout: .seconds(30))

        let connecting = Task { try await client.connect(clientID: Self.clientID) }
        #expect(await eventually { server.handshakes.count == 1 })
        connecting.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await connecting.value
        }
        #expect(await !client.isConnected)
        #expect(await eventually { server.openConnectionCount == 0 })
    }

    // MARK: - SET_ACTIVITY

    @Test func setActivitySendsTheSanitizedActivity() async throws {
        let server = try MockDiscordServer()
        defer { server.stop() }
        let client = makeClient(server)
        _ = try await client.connect(clientID: Self.clientID)

        let activity = DiscordActivity(
            details: "  Persona 4 Golden ",
            state: "x",
            timestamps: .init(start: 1_727_000_000_000),
            assets: .init(largeImage: " ", largeText: "Hover text")
        )
        try await client.setActivity(activity)

        let command = try jsonObject(try #require(server.commands.last))
        #expect(Set(command.keys) == ["cmd", "args", "nonce"])
        #expect(command["cmd"] as? String == "SET_ACTIVITY")
        #expect(UUID(uuidString: try #require(command["nonce"] as? String)) != nil)
        let args = try #require(command["args"] as? [String: Any])
        #expect(args["pid"] as? Int == 4242)
        let sent = try JSONSerialization.data(withJSONObject: try #require(args["activity"]))
        #expect(try JSONDecoder().decode(DiscordActivity.self, from: sent) == DiscordActivity(
            details: "Persona 4 Golden",
            state: "x\u{200B}",
            timestamps: .init(start: 1_727_000_000_000)
        ))
        await client.disconnect()
    }

    @Test func clearingOmitsTheActivityKey() async throws {
        let server = try MockDiscordServer()
        defer { server.stop() }
        let client = makeClient(server)
        _ = try await client.connect(clientID: Self.clientID)

        try await client.setActivity(nil)
        let command = try jsonObject(try #require(server.commands.last))
        #expect(command["cmd"] as? String == "SET_ACTIVITY")
        #expect((command["args"] as? [String: Any]).map { Set($0.keys) } == ["pid"])
        await client.disconnect()
    }

    @Test func setActivityNeedsAConnection() async throws {
        let client = DiscordIPCClient(socketPaths: { [] })
        await #expect(throws: DiscordIPCError.notConnected) {
            try await client.setActivity(DiscordActivity(details: "Game"))
        }
    }

    @Test func concurrentCommandsAreMatchedByNonce() async throws {
        let server = try MockDiscordServer(commands: .ignore)
        defer { server.stop() }
        let client = makeClient(server)
        _ = try await client.connect(clientID: Self.clientID)

        let updates = (0..<5).map { index in
            Task { try await client.setActivity(DiscordActivity(details: "Game \(index)")) }
        }
        #expect(await eventually { server.commands.count == 5 })
        let nonces = try server.commands.map { try jsonObject($0)["nonce"] as? String }
        #expect(Set(nonces).count == 5)

        // Replies come in reverse order. "Game 2" is accepted; every other one is rejected with its own message.
        var replies = Data()
        for payload in server.commands.reversed() {
            let command = try jsonObject(payload)
            let nonce = try #require(command["nonce"] as? String)
            let activity = (command["args"] as? [String: Any])?["activity"] as? [String: Any]
            let details = try #require(activity?["details"] as? String)
            let reply: [String: Any] = details == "Game 2"
                ? ["cmd": "SET_ACTIVITY", "evt": NSNull(), "nonce": nonce, "data": NSNull()]
                : ["cmd": "SET_ACTIVITY", "evt": "ERROR", "nonce": nonce, "data": ["code": 4000, "message": details]]
            replies += try jsonFrame(.frame, reply).encoded()
        }
        server.sendRaw(replies)

        for (index, update) in updates.enumerated() {
            let error = await caughtError { try await update.value }
            if index == 2 {
                #expect(error == nil)
            } else {
                #expect(error as? DiscordIPCError == .rpcError(code: 4000, message: "Game \(index)"))
            }
        }
        #expect(await client.isConnected)
        server.setCommandResponse(.success)
        await client.disconnect()
    }

    @Test func rejectedUpdateThrowsRPCErrorAndKeepsTheConnection() async throws {
        let message = #"child "activity" fails because [child "state" fails because ["state" length must be at "#
            + #"least 2 characters long]]"#
        let server = try MockDiscordServer(commands: .error(code: 4000, message: message))
        defer { server.stop() }
        let client = makeClient(server)
        _ = try await client.connect(clientID: Self.clientID)

        await #expect(throws: DiscordIPCError.rpcError(code: 4000, message: message)) {
            try await client.setActivity(DiscordActivity(details: "Game"))
        }
        #expect(await client.isConnected)
        server.setCommandResponse(.success)
        try await client.setActivity(DiscordActivity(details: "Game"))
        #expect(server.connectionCount == 1)
        await client.disconnect()
    }

    @Test func replyTimeoutClosesTheConnection() async throws {
        let server = try MockDiscordServer(commands: .ignore)
        defer { server.stop() }
        let client = makeClient(server, timeout: .milliseconds(500))
        _ = try await client.connect(clientID: Self.clientID)

        await #expect(throws: DiscordIPCError.timedOut) {
            try await client.setActivity(DiscordActivity(details: "Game"))
        }
        #expect(await !client.isConnected)
        #expect(await eventually { server.openConnectionCount == 0 })
        await #expect(throws: DiscordIPCError.notConnected) {
            try await client.setActivity(nil)
        }
    }

    @Test func cancellingSetActivityKeepsTheConnection() async throws {
        let server = try MockDiscordServer(commands: .ignore)
        defer { server.stop() }
        let client = makeClient(server, timeout: .seconds(30))
        _ = try await client.connect(clientID: Self.clientID)

        let update = Task { try await client.setActivity(DiscordActivity(details: "Game")) }
        #expect(await eventually { server.commands.count == 1 })
        update.cancel()
        await #expect(throws: CancellationError.self) {
            try await update.value
        }
        #expect(await client.isConnected)
    }

    @Test func repliesWithUnknownNoncesAreIgnored() async throws {
        let server = try MockDiscordServer(commands: .ignore)
        defer { server.stop() }
        let client = makeClient(server)
        _ = try await client.connect(clientID: Self.clientID)

        let update = Task { try await client.setActivity(DiscordActivity(details: "Game")) }
        #expect(await eventually { server.commands.count == 1 })
        let nonce = try #require(try jsonObject(server.commands[0])["nonce"] as? String)
        let error: [String: Any] = ["code": 4000, "message": "not for you"]
        let stranger = try jsonFrame(
            .frame,
            ["cmd": "SET_ACTIVITY", "evt": "ERROR", "nonce": "x-\(nonce)", "data": error]
        )
        let reply = try jsonFrame(.frame, ["cmd": "SET_ACTIVITY", "evt": NSNull(), "nonce": nonce, "data": NSNull()])
        server.sendRaw(stranger.encoded() + reply.encoded())

        try await update.value
        #expect(await client.isConnected)
        await client.disconnect()
    }

    // MARK: - Reading

    @Test func pingIsAnsweredWithAnIdenticalPong() async throws {
        let server = try MockDiscordServer()
        defer { server.stop() }
        let client = makeClient(server)
        _ = try await client.connect(clientID: Self.clientID)

        let payload = Data(#"{"nonce":"ping-1","x":[1,2]}"#.utf8)
        server.sendPing(payload)
        #expect(await eventually { server.pongs == [payload] })
        try await client.setActivity(DiscordActivity(details: "Still usable"))
        await client.disconnect()
    }

    @Test func droppedConnectionMarksTheClientDisconnected() async throws {
        let server = try MockDiscordServer()
        defer { server.stop() }
        let client = makeClient(server)
        _ = try await client.connect(clientID: Self.clientID)

        server.dropClients()
        #expect(await eventually { await !client.isConnected })
        await #expect(throws: DiscordIPCError.notConnected) {
            try await client.setActivity(DiscordActivity(details: "Game"))
        }
        // Discord is back: the next connect opens a new connection.
        _ = try await client.connect(clientID: Self.clientID)
        #expect(server.connectionCount == 2)
        await client.disconnect()
    }

    @Test func droppedConnectionFailsAPendingCommand() async throws {
        let server = try MockDiscordServer(commands: .ignore)
        defer { server.stop() }
        let client = makeClient(server, timeout: .seconds(30))
        _ = try await client.connect(clientID: Self.clientID)

        let update = Task { try await client.setActivity(DiscordActivity(details: "Game")) }
        #expect(await eventually { server.commands.count == 1 })
        server.dropClients()
        let error = await caughtError { try await update.value }
        guard case .closedByDiscord(let code, _)? = error as? DiscordIPCError else {
            Issue.record("Expected closedByDiscord, got \(String(describing: error))")
            return
        }
        #expect(code == 1006)
        #expect(await !client.isConnected)
    }

    @Test(arguments: [1000, 4000])
    func closeAfterReadyFailsPendingCommands(code: Int) async throws {
        let server = try MockDiscordServer(commands: .ignore)
        defer { server.stop() }
        let client = makeClient(server, timeout: .seconds(30))
        _ = try await client.connect(clientID: Self.clientID)

        let update = Task { try await client.setActivity(DiscordActivity(details: "Game")) }
        #expect(await eventually { server.commands.count == 1 })
        server.sendRaw(try jsonFrame(.close, ["code": code, "message": "bye"]).encoded())
        await #expect(throws: DiscordIPCError.closedByDiscord(code: code, message: "bye")) {
            try await update.value
        }
        #expect(await !client.isConnected)
    }

    @Test(arguments: MalformedInput.allCases)
    func malformedInputClosesTheConnection(input: MalformedInput) async throws {
        let server = try MockDiscordServer(commands: .ignore)
        defer { server.stop() }
        let client = makeClient(server, timeout: .seconds(30))
        _ = try await client.connect(clientID: Self.clientID)

        let update = Task { try await client.setActivity(DiscordActivity(details: "Game")) }
        #expect(await eventually { server.commands.count == 1 })
        server.sendRaw(input.bytes)
        let error = await caughtError { try await update.value }
        #expect(isProtocolViolation(error))
        #expect(await !client.isConnected)
        #expect(await eventually { server.openConnectionCount == 0 })
    }

    // MARK: - Disconnecting

    @Test func disconnectClearsTheActivityThenSendsClose() async throws {
        let server = try MockDiscordServer()
        defer { server.stop() }
        let client = makeClient(server)
        _ = try await client.connect(clientID: Self.clientID)
        try await client.setActivity(DiscordActivity(details: "Game"))

        await client.disconnect()
        #expect(await !client.isConnected)
        #expect(await eventually { server.receivedFrames.last?.opcode == .close })
        let frames = server.receivedFrames
        #expect(frames.map(\.opcode) == [.handshake, .frame, .frame, .close])
        let clear = try jsonObject(frames[2].payload)
        #expect((clear["args"] as? [String: Any]).map { Set($0.keys) } == ["pid"])
        #expect(frames.last?.payload == Data("{}".utf8))

        await client.disconnect()
        #expect(server.receivedFrames.count == 4)
        await #expect(throws: DiscordIPCError.notConnected) {
            try await client.setActivity(nil)
        }
    }

    @Test func disconnectFailsPendingCommandsWithNotConnected() async throws {
        let server = try MockDiscordServer(commands: .ignore)
        defer { server.stop() }
        let client = makeClient(server, timeout: .seconds(30))
        _ = try await client.connect(clientID: Self.clientID)

        let update = Task { try await client.setActivity(DiscordActivity(details: "Game")) }
        #expect(await eventually { server.commands.count == 1 })
        let start = ContinuousClock.now
        await client.disconnect() // The clear isn't answered either; disconnect gives up on it after ~1 s.
        #expect(ContinuousClock.now - start < .seconds(5))
        await #expect(throws: DiscordIPCError.notConnected) {
            try await update.value
        }
        #expect(await eventually { server.receivedFrames.last?.opcode == .close })
        #expect(server.receivedFrames.map(\.opcode) == [.handshake, .frame, .frame, .close])
    }

    @Test func overlappingConnectsSettleOnOneConnection() async throws {
        let server = try MockDiscordServer()
        defer { server.stop() }
        let client = makeClient(server)

        async let first = try? client.connect(clientID: "1111111111111111111")
        async let second = try? client.connect(clientID: "2222222222222222222")
        let results = await [first, second]
        #expect(results.contains { $0 != nil })
        #expect(await client.isConnected)
        await client.disconnect()
        #expect(await eventually { server.openConnectionCount == 0 })
    }

    @Test func releasingTheClientClosesItsSocket() async throws {
        let server = try MockDiscordServer()
        defer { server.stop() }
        weak var released: DiscordIPCClient?
        do {
            let client = makeClient(server)
            _ = try await client.connect(clientID: Self.clientID)
            released = client
        }
        #expect(await eventually { released == nil })
        #expect(await eventually { server.openConnectionCount == 0 })
    }

    @Test func disconnectWithoutAConnectionDoesNothing() async {
        let client = DiscordIPCClient(socketPaths: { [] })
        await client.disconnect()
        #expect(await !client.isConnected)
    }

    // MARK: - Helpers

    private func makeClient(_ server: MockDiscordServer, timeout: Duration = .seconds(5)) -> DiscordIPCClient {
        DiscordIPCClient(socketPaths: { [server.socketPath] }, timeout: timeout, processID: 4242)
    }
}

/// Bytes Discord should never send.
enum MalformedInput: CaseIterable, Sendable {
    case unknownOpcode, oversizedFrame, notJSON, notAnObject

    var bytes: Data {
        switch self {
        case .unknownOpcode:
            frameHeader(opcode: 9, length: 2) + Data("{}".utf8)
        case .oversizedFrame:
            frameHeader(opcode: 1, length: DiscordFrame.maximumPayloadLength + 1)
        case .notJSON:
            DiscordFrame(opcode: .frame, payload: Data("not json".utf8)).encoded()
        case .notAnObject:
            DiscordFrame(opcode: .frame, payload: Data("[1,2]".utf8)).encoded()
        }
    }
}

/// Candidate paths that must all be skipped: missing, a stale socket nobody listens on (ECONNREFUSED), a
/// regular file, and one too long for `sockaddr_un` (`NWEndpoint.unix(path:)` would trap on it).
struct UnusableSockets: Sendable {
    let paths: [String]
    private let stale: String
    private let file: String
    private let staleDescriptor: Int32

    init(in directory: String) throws {
        let stale = directory + "/discord-ipc-3"
        let file = directory + "/discord-ipc-4"
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(stale.utf8)) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0)
        try #require(FileManager.default.createFile(atPath: file, contents: Data()))
        self.stale = stale
        self.file = file
        staleDescriptor = descriptor
        paths = [directory + "/discord-ipc-1", stale, file, directory + "/" + String(repeating: "x", count: 120)]
    }

    func remove() {
        close(staleDescriptor)
        unlink(stale)
        unlink(file)
    }
}

import Network
import Testing
import TestSupport
@testable import VitaKit

/// `VitaClient` against a loopback `MockVitaServer`.
struct VitaClientTests {
    let persona = VitaTitle(index: 3, titleID: "PCSE00120", name: "Persona 4 Golden")

    private func client(
        for server: MockVitaServer,
        connectTimeout: Duration = .seconds(2),
        readTimeout: Duration = .seconds(2)
    ) -> VitaClient {
        VitaClient(port: server.port, connectTimeout: connectTimeout, readTimeout: readTimeout)
    }

    @Test func fetchesTheTitle() async throws {
        let server = try await MockVitaServer(behavior: .packet(persona))
        defer { server.stop() }
        #expect(try await client(for: server).fetchTitle(from: "127.0.0.1") == persona)
        #expect(server.connectionCount == 1)
    }

    @Test func eachFetchIsOneConnection() async throws {
        let server = try await MockVitaServer(behavior: .packet(persona))
        defer { server.stop() }
        let client = client(for: server)
        #expect(try await client.fetchTitle(from: "127.0.0.1") == persona)
        server.setBehavior(.packet(.liveArea))
        #expect(try await client.fetchTitle(from: "127.0.0.1") == .liveArea)
        #expect(server.connectionCount == 2)
    }

    @Test func acceptsA146BytePacket() async throws {
        let server = try await MockVitaServer(behavior: .raw(Array(VitaPacket.encode(persona).prefix(146))))
        defer { server.stop() }
        #expect(try await client(for: server).fetchTitle(from: "127.0.0.1") == persona)
    }

    @Test func parsesTheStartOfAnOversizedReply() async throws {
        let reply = VitaPacket.encode(persona) + Array(repeating: 0xAB, count: 6000)
        let server = try await MockVitaServer(behavior: .raw(reply))
        defer { server.stop() }
        #expect(try await client(for: server).fetchTitle(from: "127.0.0.1") == persona)
    }

    @Test func stopsReadingAtTheCapWithoutWaitingForEOF() async throws {
        // The first 4096 bytes arrive at once; the rest would only follow after 10 s.
        let reply = VitaPacket.encode(persona) + Array(repeating: 0xAB, count: 8000)
        let server = try await MockVitaServer(
            behavior: .chunked(reply, chunkSize: VitaPacket.maximumReadLength, delay: .seconds(10))
        )
        defer { server.stop() }
        let start = ContinuousClock.now
        #expect(try await client(for: server, readTimeout: .seconds(5)).fetchTitle(from: "127.0.0.1") == persona)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func reassemblesAPacketSentInPieces() async throws {
        let server = try await MockVitaServer(
            behavior: .chunked(VitaPacket.encode(persona), chunkSize: 7, delay: .milliseconds(20))
        )
        defer { server.stop() }
        #expect(try await client(for: server, readTimeout: .seconds(5)).fetchTitle(from: "127.0.0.1") == persona)
    }

    @Test func silentServerTimesOut() async throws {
        let server = try await MockVitaServer(behavior: .silent)
        defer { server.stop() }
        let client = client(for: server, connectTimeout: .milliseconds(300), readTimeout: .milliseconds(300))
        let start = ContinuousClock.now
        await #expect(throws: VitaConnectionError.timedOut) { try await client.fetchTitle(from: "127.0.0.1") }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .milliseconds(250))
        #expect(elapsed < .seconds(2))
        #expect(server.connectionCount == 1)
    }

    @Test func connectTimeoutStopsApplyingOnceConnected() async throws {
        let server = try await MockVitaServer(behavior: .silent)
        defer { server.stop() }
        let client = client(for: server, connectTimeout: .milliseconds(50), readTimeout: .milliseconds(600))
        let start = ContinuousClock.now
        await #expect(throws: VitaConnectionError.timedOut) { try await client.fetchTitle(from: "127.0.0.1") }
        #expect(ContinuousClock.now - start >= .milliseconds(550))
    }

    @Test func stoppedServerEndsTheReadWithAnIncompletePacket() async throws {
        let server = try await MockVitaServer(behavior: .silent)
        let client = client(for: server, readTimeout: .seconds(10))
        let fetch = Task { try await client.fetchTitle(from: "127.0.0.1") }
        #expect(await eventually { server.connectionCount == 1 })
        server.stop()
        server.stop()
        await #expect(throws: VitaConnectionError.incompletePacket(byteCount: 0)) { try await fetch.value }
    }

    @Test func closingWithoutDataIsAnIncompletePacket() async throws {
        let server = try await MockVitaServer(behavior: .closeImmediately)
        defer { server.stop() }
        await #expect(throws: VitaConnectionError.incompletePacket(byteCount: 0)) {
            try await client(for: server).fetchTitle(from: "127.0.0.1")
        }
    }

    @Test(arguments: [1, 100, 145])
    func shortReplyIsAnIncompletePacket(length: Int) async throws {
        let server = try await MockVitaServer(behavior: .raw(Array(VitaPacket.encode(persona).prefix(length))))
        defer { server.stop() }
        await #expect(throws: VitaConnectionError.incompletePacket(byteCount: length)) {
            try await client(for: server).fetchTitle(from: "127.0.0.1")
        }
    }

    @Test func badMagicIsAnInvalidPacket() async throws {
        let server = try await MockVitaServer(behavior: .raw(VitaPacket.encode(persona, magic: 0x4854_5450)))
        defer { server.stop() }
        await #expect(throws: VitaConnectionError.invalidPacket(.badMagic(0x4854_5450))) {
            try await client(for: server).fetchTitle(from: "127.0.0.1")
        }
    }

    @Test func invalidIndexIsAnInvalidPacket() async throws {
        let server = try await MockVitaServer(behavior: .packet(VitaTitle(index: 99, titleID: "X", name: "Y")))
        defer { server.stop() }
        await #expect(throws: VitaConnectionError.invalidPacket(.invalidIndex(99))) {
            try await client(for: server).fetchTitle(from: "127.0.0.1")
        }
    }

    @Test func refusedConnectionFailsFast() async throws {
        let server = try await MockVitaServer(behavior: .packet(persona))
        let client = VitaClient(port: server.port, connectTimeout: .seconds(5), readTimeout: .seconds(5))
        server.stop()
        // The listening socket closes asynchronously, so retry until the port refuses.
        var lastError: VitaConnectionError?
        let deadline = ContinuousClock.now + .seconds(3)
        while lastError != .refused, ContinuousClock.now < deadline {
            let start = ContinuousClock.now
            lastError = await #expect(throws: VitaConnectionError.self) {
                try await client.fetchTitle(from: "127.0.0.1")
            }
            if lastError == .refused {
                #expect(ContinuousClock.now - start < .seconds(1))
            }
        }
        #expect(lastError == .refused)
    }

    @Test func cancellingTheCallerThrowsCancellationErrorPromptly() async throws {
        let server = try await MockVitaServer(behavior: .silent)
        defer { server.stop() }
        let client = client(for: server, connectTimeout: .seconds(10), readTimeout: .seconds(10))
        let fetch = Task { try await client.fetchTitle(from: "127.0.0.1") }
        #expect(await eventually { server.connectionCount == 1 })
        let start = ContinuousClock.now
        fetch.cancel()
        await #expect(throws: CancellationError.self) { try await fetch.value }
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func alreadyCancelledCallerNeverConnects() async throws {
        let server = try await MockVitaServer(behavior: .packet(persona))
        defer { server.stop() }
        let client = client(for: server)
        let fetch = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.fetchTitle(from: "127.0.0.1")
        }
        await #expect(throws: CancellationError.self) { try await fetch.value }
        #expect(server.connectionCount == 0)
    }

    @Test(arguments: [
        "", "localhost", "vita.local", "192.168.001.1", "192.168.1", "127.0.0.1:51966", "::1", " 127.0.0.1",
    ])
    func rejectsHostsThatAreNotIPv4Literals(host: String) async throws {
        let client = VitaClient(connectTimeout: .milliseconds(100), readTimeout: .milliseconds(100))
        let error = try await #require(throws: VitaConnectionError.self) { try await client.fetchTitle(from: host) }
        guard case .unresolvedAddress(let message) = error else {
            Issue.record("expected .unresolvedAddress, got \(error)")
            return
        }
        #expect(message.contains("“\(host)”"))
    }
}

struct VitaClientErrorMappingTests {
    @Test(arguments: [
        (NWError.posix(.ECONNREFUSED), VitaConnectionError.refused),
        (.posix(.ETIMEDOUT), .timedOut),
        (.posix(.EHOSTUNREACH), .unreachable("No route to host")),
        (.posix(.EHOSTDOWN), .unreachable("Host is down")),
        (.posix(.ENETUNREACH), .unreachable("Network is unreachable")),
        (.posix(.ENETDOWN), .unreachable("Network is down")),
        (.posix(.ECONNRESET), .other("Connection reset by peer")),
    ])
    func mapsPOSIXErrors(error: NWError, expected: VitaConnectionError) {
        #expect(VitaClient.connectionError(for: error, unsatisfiedReason: nil) == expected)
        #expect(VitaClient.connectionError(for: error, unsatisfiedReason: .notAvailable) == expected)
    }

    @Test(arguments: [NWError.posix(.EHOSTUNREACH), .posix(.ECONNREFUSED), .posix(.ENETDOWN), .dns(-65570)])
    func localNetworkDenialWinsOverTheReportedError(error: NWError) {
        let mapped = VitaClient.connectionError(for: error, unsatisfiedReason: .localNetworkDenied)
        #expect(mapped == .localNetworkDenied)
    }

    @Test func otherErrorsKeepADescription() {
        let mapped = VitaClient.connectionError(for: .dns(-65554), unsatisfiedReason: nil)
        guard case .other(let message) = mapped else {
            Issue.record("expected .other")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test func mapsPacketProblems() {
        let persona = VitaTitle(index: 3, titleID: "PCSE00120", name: "Persona 4 Golden")
        #expect(VitaClient.title(from: VitaPacket.encode(persona)) == .success(persona))
        #expect(VitaClient.title(from: []) == .failure(.incompletePacket(byteCount: 0)))
        let truncated = Array(VitaPacket.encode(persona).prefix(145))
        #expect(VitaClient.title(from: truncated) == .failure(.incompletePacket(byteCount: 145)))
        #expect(VitaClient.title(from: Array(repeating: 0, count: 148)) == .failure(.invalidPacket(.badMagic(0))))
    }
}

struct VitaConnectionErrorTests {
    @Test(arguments: [
        (VitaConnectionError.timedOut, "Vita not responding. Is it awake and on the same Wi-Fi?"),
        (.refused, "Found the Vita, but the VitaPresence plugin isn't running"),
        (.localNetworkDenied, "Local Network access is turned off for VitaPresence"),
        (.unreachable("No route to host"), "Can't reach the Vita (No route to host)"),
        (.incompletePacket(byteCount: 12), "Unexpected reply. Is this the right device?"),
        (.invalidPacket(.badMagic(0)), "Unexpected reply. Is this the right device?"),
        (.unresolvedAddress("Couldn't find the Vita"), "Couldn't find the Vita"),
        (.other("Connection reset by peer"), "Connection reset by peer"),
    ])
    func userMessages(error: VitaConnectionError, message: String) {
        #expect(error.userMessage == message)
    }
}

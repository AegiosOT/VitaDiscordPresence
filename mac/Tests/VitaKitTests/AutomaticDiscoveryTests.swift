import Testing
@testable import VitaKit

/// A clock that moves only when a test says so.
private final class FakeClock: Sendable {
    private let instant = Locked(ContinuousClock.now)

    var now: ContinuousClock.Instant { instant.value }

    func advance(by duration: Duration) {
        instant.withLock { $0 = $0 + duration }
    }
}

/// A LAN where the Vitas that are awake answer polls and scans. Counts scans.
private final class FakeLAN: Sendable {
    private struct State {
        var vitas: [String] = []
        var macs: [String: MACAddress] = [:]
        var isDenied = false
        var holdsNextScan = false
        var isHolding = false
        var scans = 0
    }

    private let state = Locked(State())

    /// Scans started so far.
    var scans: Int { state.value.scans }

    /// Whether a scan held by `holdNextScan()` is waiting.
    var isHolding: Bool { state.value.isHolding }

    /// Makes exactly these hosts answer, in this order.
    func setVitas(_ hosts: [String]) {
        state.withLock { $0.vitas = hosts }
    }

    /// MAC addresses reported for hosts from `setVitas`. Hosts left out have none.
    func setMACAddresses(_ macs: [String: MACAddress]) {
        state.withLock { $0.macs = macs }
    }

    /// Makes polls and scans fail as before the user allows Local Network access.
    func setDenied(_ isDenied: Bool) {
        state.withLock { $0.isDenied = isDenied }
    }

    /// Makes the next scan wait before it looks, until `release()` or cancellation. Later scans don't wait. A
    /// held scan gives up waiting after 10 s, so that a broken resolver fails a test instead of hanging it.
    func holdNextScan() {
        state.withLock { $0.holdsNextScan = true }
    }

    func release() {
        state.withLock { $0.isHolding = false }
    }

    /// Whether polling `host` succeeds.
    func answers(at host: String) -> Bool {
        let current = state.value
        return !current.isDenied && current.vitas.contains(host)
    }

    func scan() async throws -> [DiscoveredVita] {
        let isHeld = state.withLock { state in
            state.scans += 1
            guard state.holdsNextScan else { return false }
            state.holdsNextScan = false
            state.isHolding = true
            return true
        }
        if isHeld {
            defer { state.withLock { $0.isHolding = false } }
            let deadline = ContinuousClock.now + .seconds(10)
            while state.value.isHolding, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        let current = state.value
        if current.isDenied { throw VitaConnectionError.localNetworkDenied }
        return current.vitas.map {
            DiscoveredVita(ipAddress: $0, macAddress: current.macs[$0], title: fakeTitle($0))
        }
    }
}

/// `VitaResolver` with `.automatic`, on a fake LAN and a fake clock: nothing touches the network, and no test
/// waits for the delays between scans.
struct AutomaticDiscoveryTests {
    static let noVitaMessage =
        "No Vita found on this network. Is it awake, on the same Wi-Fi, and running the VitaPresence plugin?"

    private let lan = FakeLAN()
    private let clock = FakeClock()

    /// A resolver with the real delays between scans (30 s, doubling up to 5 minutes) on the fake clock.
    private func resolver(knownHost: String? = nil, knownMAC: MACAddress? = nil) -> VitaResolver {
        VitaResolver(
            scan: { [lan] in try await lan.scan() },
            arpLookup: { _ in nil },
            knownHost: knownHost,
            knownMAC: knownMAC,
            now: { [clock] in clock.now }
        )
    }

    /// One poll as `PresenceController` makes it: resolves the address, then reports a failure unless a Vita
    /// answers at the host.
    @discardableResult
    private func poll(_ resolver: VitaResolver) async throws -> String {
        let host = try await resolver.resolve(.automatic)
        if !lan.answers(at: host) {
            await resolver.invalidate(.automatic)
        }
        return host
    }

    /// Expects `resolve(.automatic)` to throw `.unresolvedAddress`, reports the failure as the controller does,
    /// and returns the message.
    @discardableResult
    private func unresolvedMessage(
        _ resolver: VitaResolver,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> String {
        let error = try await #require(throws: VitaConnectionError.self, sourceLocation: sourceLocation) {
            try await resolver.resolve(.automatic)
        }
        await resolver.invalidate(.automatic)
        switch error {
        case .unresolvedAddress(let message): return message
        case .severalVitas: return error.userMessage
        default:
            Issue.record("expected a discovery failure, got \(error)", sourceLocation: sourceLocation)
            return ""
        }
    }

    /// Two failed polls of a known host, which is what it takes before the next resolve may scan.
    private func missTwice(_ resolver: VitaResolver) async throws {
        _ = try await poll(resolver)
        _ = try await poll(resolver)
        #expect(lan.scans == 0)
    }

    // MARK: The known host

    @Test func pollsTheKnownHostWithoutScanning() async throws {
        lan.setVitas(["192.0.2.20", "192.0.2.21"])
        let resolver = resolver(knownHost: "192.0.2.20")
        for _ in 0..<3 {
            #expect(try await poll(resolver) == "192.0.2.20")
            clock.advance(by: .seconds(600))
        }
        #expect(lan.scans == 0)
        #expect(await resolver.automaticHost == "192.0.2.20")
    }

    @Test(arguments: ["", "vita.local", "192.168.001.20", "192.0.2.20:51966", " 192.0.2.20", "a4:5e:60:01:02:03"])
    func ignoresAKnownHostThatIsntAnIPv4Address(knownHost: String) async throws {
        lan.setVitas(["192.0.2.21"])
        let resolver = resolver(knownHost: knownHost)
        #expect(await resolver.automaticHost == nil)
        #expect(try await poll(resolver) == "192.0.2.21")
        #expect(lan.scans == 1)
    }

    @Test func onlyAFailedAutomaticPollCountsAgainstTheKnownHost() async throws {
        let resolver = resolver(knownHost: "192.0.2.20")
        #expect(try await resolver.resolve(.automatic) == "192.0.2.20")
        await resolver.invalidate(.ipv4("192.0.2.20"))
        await resolver.invalidate(.mac(try #require(MACAddress("a4:5e:60:01:02:03"))))
        #expect(try await resolver.resolve(.automatic) == "192.0.2.20")
        #expect(lan.scans == 0)
    }

    // MARK: Scan results

    @Test func scansOnTheFirstRunAndKeepsTheOnlyVita() async throws {
        lan.setVitas(["192.0.2.21"])
        let resolver = resolver()
        #expect(try await poll(resolver) == "192.0.2.21")
        #expect(lan.scans == 1)
        #expect(await resolver.automaticHost == "192.0.2.21")
        clock.advance(by: .seconds(600))
        #expect(try await poll(resolver) == "192.0.2.21")
        #expect(try await poll(resolver) == "192.0.2.21")
        #expect(lan.scans == 1)
    }

    @Test func doesNotReplaceASleepingKnownHostWithTheOnlyOtherVita() async throws {
        lan.setVitas(["192.0.2.34"])
        let resolver = resolver(knownHost: "192.0.2.20")
        try await missTwice(resolver)
        let message = try await unresolvedMessage(resolver)
        #expect(message == "Found 1 Vita: 192.0.2.34 — set its address")
        #expect(lan.scans == 1)
        #expect(await resolver.automaticHost == "192.0.2.20")
        // It keeps failing at the remembered address instead of staying on the stranger.
        clock.advance(by: .seconds(30))
        #expect(try await unresolvedMessage(resolver) == message)
        #expect(await resolver.automaticHost == "192.0.2.20")
    }

    @Test func prefersTheKnownHostAmongSeveralVitas() async throws {
        let resolver = resolver(knownHost: "192.0.2.21")
        // The plugin restarted; by the scan it answers again, next to other Vitas.
        try await missTwice(resolver)
        lan.setVitas(["192.0.2.20", "192.0.2.21", "192.0.2.22"])
        #expect(try await poll(resolver) == "192.0.2.21")
        #expect(try await poll(resolver) == "192.0.2.21")
        #expect(lan.scans == 1)
    }

    @Test func namesSeveralVitasUntilTheNextScan() async throws {
        lan.setVitas(["192.168.1.20", "192.168.1.21"])
        let resolver = resolver()
        let message = try await unresolvedMessage(resolver)
        #expect(message == "Found 2 Vitas: 192.168.1.20, 192.168.1.21 — set its address")
        clock.advance(by: .seconds(29))
        #expect(try await unresolvedMessage(resolver) == message)
        #expect(lan.scans == 1)

        lan.setVitas(["192.168.1.21"])
        clock.advance(by: .seconds(1))
        #expect(try await poll(resolver) == "192.168.1.21")
        #expect(lan.scans == 2)
    }

    @Test func namesSeveralVitasElsewhereInsteadOfPollingAFailingKnownHost() async throws {
        lan.setVitas(["192.0.2.21", "192.0.2.22"])
        let resolver = resolver(knownHost: "192.0.2.20")
        try await missTwice(resolver)
        let message = try await unresolvedMessage(resolver)
        #expect(message == "Found 2 Vitas: 192.0.2.21, 192.0.2.22 — set its address")
        #expect(try await unresolvedMessage(resolver) == message)
        #expect(lan.scans == 1)
        #expect(await resolver.automaticHost == "192.0.2.20")

        // Back at its address, the Vita is found among the others by the next scan.
        lan.setVitas(["192.0.2.20", "192.0.2.21", "192.0.2.22"])
        clock.advance(by: .seconds(30))
        #expect(try await poll(resolver) == "192.0.2.20")
        #expect(lan.scans == 2)
    }

    @Test func aScanThatFindsNoVitaAfterSeveralKeepsTheKnownHost() async throws {
        lan.setVitas(["192.0.2.21", "192.0.2.22"])
        let resolver = resolver(knownHost: "192.0.2.20")
        try await missTwice(resolver)
        try await unresolvedMessage(resolver)  // several Vitas, none at the known host

        // They are switched off too: everything is asleep, so the known host is polled again.
        lan.setVitas([])
        clock.advance(by: .seconds(30))
        #expect(try await poll(resolver) == "192.0.2.20")
        #expect(lan.scans == 2)
        #expect(try await poll(resolver) == "192.0.2.20")
        #expect(lan.scans == 2)
    }

    @Test func reportsThatNoVitaWasFoundUntilTheNextScan() async throws {
        let resolver = resolver()
        let message = try await unresolvedMessage(resolver)
        #expect(message == Self.noVitaMessage)
        clock.advance(by: .seconds(29))
        #expect(try await unresolvedMessage(resolver) == message)
        #expect(lan.scans == 1)
        clock.advance(by: .seconds(1))
        #expect(try await unresolvedMessage(resolver) == message)
        #expect(lan.scans == 2)
    }

    @Test func aVitaThatMovedIsNotAdoptedWhileTheOldAddressIsRemembered() async throws {
        let resolver = resolver(knownHost: "192.0.2.20")
        try await missTwice(resolver)
        #expect(try await poll(resolver) == "192.0.2.20")  // asleep: the scan finds nothing
        #expect(lan.scans == 1)

        // It wakes up with another address. That single answer is not taken: it might be a different Vita.
        lan.setVitas(["192.0.2.34"])
        clock.advance(by: .seconds(30))
        let message = try await unresolvedMessage(resolver)
        #expect(message == "Found 1 Vita: 192.0.2.34 — set its address")
        #expect(lan.scans == 2)
        #expect(await resolver.automaticHost == "192.0.2.20")
    }

    @Test func adoptsTheVitaWhoseMACMatchesWhenTheOldAddressIsGone() async throws {
        let mac = try #require(MACAddress("a4:5e:60:01:02:03"))
        lan.setMACAddresses(["192.0.2.34": mac])
        lan.setVitas(["192.0.2.34"])
        let resolver = resolver(knownHost: "192.0.2.20", knownMAC: mac)
        try await missTwice(resolver)

        #expect(try await poll(resolver) == "192.0.2.34")
        #expect(lan.scans == 1)
        #expect(await resolver.automaticHost == "192.0.2.34")
        #expect(try await poll(resolver) == "192.0.2.34")
        #expect(lan.scans == 1)
    }

    @Test func doesNotAdoptAStrangerWhoseMACDoesNotMatch() async throws {
        let known = try #require(MACAddress("a4:5e:60:01:02:03"))
        let other = try #require(MACAddress("b4:5e:60:09:08:07"))
        lan.setMACAddresses(["192.0.2.34": other])
        lan.setVitas(["192.0.2.34"])
        let resolver = resolver(knownHost: "192.0.2.20", knownMAC: known)
        try await missTwice(resolver)

        let message = try await unresolvedMessage(resolver)
        #expect(message == "Found 1 Vita: 192.0.2.34 — set its address")
        #expect(await resolver.automaticHost == "192.0.2.20")
    }

    @Test func rememberingAProfilePollsItsAddressWithoutScanning() async throws {
        lan.setVitas(["192.0.2.21"])
        let mac = try #require(MACAddress("a4:5e:60:01:02:03"))
        let resolver = resolver(knownHost: "192.0.2.20")

        await resolver.remember(host: "192.0.2.21", macAddress: mac)

        #expect(try await poll(resolver) == "192.0.2.21")
        #expect(lan.scans == 0)
        #expect(await resolver.automaticHost == "192.0.2.21")
    }

    // MARK: Waiting between scans

    @Test func keepsTheKnownHostOfASleepingVitaAndScansLessAndLessOften() async throws {
        let resolver = resolver(knownHost: "192.0.2.20")
        #expect(try await poll(resolver) == "192.0.2.20")
        #expect(lan.scans == 0)
        // Two failures are needed before a scan. It finds nothing, so the known host stays.
        #expect(try await poll(resolver) == "192.0.2.20")
        #expect(lan.scans == 0)
        #expect(try await poll(resolver) == "192.0.2.20")
        #expect(lan.scans == 1)
        for (scans, seconds) in zip(2..., [30, 60, 120, 240, 300, 300]) {
            clock.advance(by: .seconds(seconds - 1))
            #expect(try await poll(resolver) == "192.0.2.20")
            #expect(lan.scans == scans - 1, "\(seconds) s haven't passed yet")
            clock.advance(by: .seconds(1))
            #expect(try await poll(resolver) == "192.0.2.20")
            #expect(lan.scans == scans, "\(seconds) s have passed")
        }
        #expect(await resolver.automaticHost == "192.0.2.20")
    }

    @Test func theDelaysBetweenScansAreConfigurable() async throws {
        let resolver = VitaResolver(
            scan: { [lan] in try await lan.scan() },
            arpLookup: { _ in nil },
            automaticScanDelay: .seconds(2),
            maximumAutomaticScanDelay: .seconds(5),
            now: { [clock] in clock.now }
        )
        try await unresolvedMessage(resolver)
        for (scans, seconds) in zip(2..., [2, 4, 5, 5]) {
            clock.advance(by: .seconds(seconds) - .milliseconds(1))
            try await unresolvedMessage(resolver)
            #expect(lan.scans == scans - 1)
            clock.advance(by: .milliseconds(1))
            try await unresolvedMessage(resolver)
            #expect(lan.scans == scans)
        }
    }

    @Test func aKnownHostThatAnswersAgainIsNoLongerScannedFor() async throws {
        let resolver = resolver(knownHost: "192.0.2.20")
        try await missTwice(resolver)
        try await poll(resolver)  // asleep: the scan finds nothing
        lan.setVitas(["192.0.2.20"])
        #expect(try await poll(resolver) == "192.0.2.20")
        for _ in 0..<3 {
            clock.advance(by: .seconds(600))
            #expect(try await poll(resolver) == "192.0.2.20")
        }
        #expect(lan.scans == 1)
    }

    @Test func aPollThatAnswersResetsTheWait() async throws {
        let resolver = resolver(knownHost: "192.0.2.20")
        try await missTwice(resolver)
        try await poll(resolver)  // scan 1 finds nothing
        clock.advance(by: .seconds(30))
        try await poll(resolver)  // scan 2 finds nothing, so the next one would wait 60 s
        #expect(lan.scans == 2)

        // The Vita wakes up where it was and answers.
        lan.setVitas(["192.0.2.20"])
        #expect(try await poll(resolver) == "192.0.2.20")
        #expect(try await poll(resolver) == "192.0.2.20")
        #expect(lan.scans == 2)

        // Asleep again: two misses, then a scan 30 s after the last one.
        lan.setVitas([])
        try await poll(resolver)
        try await poll(resolver)
        #expect(lan.scans == 2)
        clock.advance(by: .seconds(30))
        try await poll(resolver)
        #expect(lan.scans == 3)
    }

    @Test func aScanThatFindsTheVitaResetsTheWait() async throws {
        let resolver = resolver()
        try await unresolvedMessage(resolver)  // scan 1
        clock.advance(by: .seconds(30))
        try await unresolvedMessage(resolver)  // scan 2, so the next one waits 60 s
        clock.advance(by: .seconds(60))
        lan.setVitas(["192.0.2.21"])
        #expect(try await poll(resolver) == "192.0.2.21")
        #expect(lan.scans == 3)

        // It goes away right after: a scan may look for it 30 s after the last one.
        lan.setVitas([])
        try await poll(resolver)
        clock.advance(by: .seconds(29))
        try await poll(resolver)
        #expect(lan.scans == 3)
        clock.advance(by: .seconds(1))
        #expect(try await poll(resolver) == "192.0.2.21")
        #expect(lan.scans == 4)
    }

    // MARK: Scans that didn't look

    @Test func localNetworkDenialIsThrownAndDoesntCountAgainstTheWait() async throws {
        let resolver = resolver()
        try await unresolvedMessage(resolver)  // scan 1 finds nothing, so the next one waits 30 s
        clock.advance(by: .seconds(30))
        lan.setDenied(true)
        await #expect(throws: VitaConnectionError.localNetworkDenied) { try await resolver.resolve(.automatic) }
        await #expect(throws: VitaConnectionError.localNetworkDenied) { try await resolver.resolve(.automatic) }
        #expect(lan.scans == 3)

        // Once allowed, a scan runs right away.
        lan.setDenied(false)
        lan.setVitas(["192.0.2.21"])
        #expect(try await poll(resolver) == "192.0.2.21")
        #expect(lan.scans == 4)
    }

    @Test func localNetworkDenialIsThrownInsteadOfAFailingKnownHost() async throws {
        let resolver = resolver(knownHost: "192.0.2.20")
        lan.setDenied(true)
        try await missTwice(resolver)
        await #expect(throws: VitaConnectionError.localNetworkDenied) { try await resolver.resolve(.automatic) }
        #expect(lan.scans == 1)
        #expect(await resolver.automaticHost == "192.0.2.20")

        lan.setDenied(false)
        #expect(try await poll(resolver) == "192.0.2.20")  // asleep: the scan finds nothing
        #expect(lan.scans == 2)
    }

    @Test func aCancelledScanDoesntCountAgainstTheWait() async throws {
        lan.setVitas(["192.0.2.21"])
        lan.holdNextScan()
        let resolver = resolver()
        let firstAttempt = Task { try await resolver.resolve(.automatic) }
        #expect(await eventually { lan.isHolding })
        firstAttempt.cancel()
        await #expect(throws: CancellationError.self) { try await firstAttempt.value }

        #expect(try await poll(resolver) == "192.0.2.21")
        #expect(lan.scans == 2)
    }

    // MARK: Calls during a scan

    @Test func aCallDuringAScanGetsTheKnownHostWithoutScanningAgain() async throws {
        let resolver = resolver(knownHost: "192.0.2.20")
        try await missTwice(resolver)
        lan.holdNextScan()
        let scanning = Task { try await resolver.resolve(.automatic) }
        #expect(await eventually { lan.isHolding })
        clock.advance(by: .seconds(600))  // a slow scan: the wait is over before it ends
        #expect(try await resolver.resolve(.automatic) == "192.0.2.20")

        lan.setVitas(["192.0.2.34"])
        lan.release()
        await #expect(throws: VitaConnectionError.self) { try await scanning.value }
        #expect(lan.scans == 1)
        #expect(await resolver.automaticHost == "192.0.2.20")
    }

    @Test func aCallDuringTheFirstScanFailsWithoutScanningAgain() async throws {
        lan.setVitas(["192.0.2.21"])
        lan.holdNextScan()
        let resolver = resolver()
        let scanning = Task { try await resolver.resolve(.automatic) }
        #expect(await eventually { lan.isHolding })
        clock.advance(by: .seconds(600))
        #expect(try await unresolvedMessage(resolver) == Self.noVitaMessage)

        lan.release()
        #expect(try await scanning.value == "192.0.2.21")
        #expect(lan.scans == 1)
    }

    // MARK: The real scanner

    @Test func thePublicInitializerScansWithTheVitaScanner() async throws {
        let fetcher = FakeFetcher { host in
            guard host == "192.0.2.8" else { throw VitaConnectionError.refused }
            return fakeTitle("Persona")
        }
        let scanner = VitaScanner(
            fetcher: fetcher,
            maxConcurrentProbes: 4,
            hostLimit: 1024,
            localHosts: { ["192.0.2.7", "192.0.2.8"] },
            macAddressLookup: { _ in nil }
        )
        #expect(try await VitaResolver(scanner: scanner).resolve(.automatic) == "192.0.2.8")
        #expect(fetcher.calls.sorted() == ["192.0.2.7", "192.0.2.8"])

        #expect(try await VitaResolver(scanner: scanner, knownHost: "192.0.2.8").resolve(.automatic) == "192.0.2.8")
        #expect(fetcher.calls.count == 2, "the known host needs no scan")
    }

    @Test func retryDiscoveryScansAgainWithoutWaiting() async throws {
        let resolver = resolver()
        _ = try await unresolvedMessage(resolver)
        #expect(lan.scans == 1)
        await resolver.retryDiscovery()
        _ = try await unresolvedMessage(resolver)
        #expect(lan.scans == 2)
    }

    @Test func aScanWithNoNetworkDoesNotGrowTheWait() async throws {
        let resolver = VitaResolver(
            scan: { throw VitaConnectionError.noLocalNetwork },
            knownHost: nil,
            now: { [clock] in clock.now }
        )
        await #expect(throws: VitaConnectionError.noLocalNetwork) { try await resolver.resolve(.automatic) }
        await #expect(throws: VitaConnectionError.noLocalNetwork) { try await resolver.resolve(.automatic) }
    }
}

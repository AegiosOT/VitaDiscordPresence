import Testing
@testable import VitaKit

/// A fake ARP cache that counts lookups.
private final class FakeARPCache: Sendable {
    private let state = Locked((entries: [MACAddress: String](), lookups: 0))

    var lookups: Int { state.value.lookups }

    func lookup(_ mac: MACAddress) -> String? {
        state.withLock { state in
            state.lookups += 1
            return state.entries[mac]
        }
    }

    func set(_ host: String, for mac: MACAddress) {
        state.withLock { $0.entries[mac] = host }
    }
}

/// `VitaResolver` with a fake ARP cache and a scanner over two fake hosts; nothing touches the network.
struct VitaResolverTests {
    let mac = MACAddress("a4:5e:60:01:02:03")!
    let otherMAC = MACAddress("a4:5e:60:01:02:04")!
    private let arp = FakeARPCache()

    private func resolver(
        fetcher: FakeFetcher,
        scanResultMACs: [String: MACAddress] = [:],
        minimumScanInterval: Duration = .seconds(60)
    ) -> VitaResolver {
        let scanner = VitaScanner(
            fetcher: fetcher,
            maxConcurrentProbes: 4,
            hostLimit: 1024,
            localHosts: { ["192.0.2.7", "192.0.2.8"] },
            macAddressLookup: { scanResultMACs[$0] }
        )
        return VitaResolver(
            scanner: scanner,
            arpLookup: { [arp] in arp.lookup($0) },
            minimumScanInterval: minimumScanInterval
        )
    }

    /// A fetcher where only 192.0.2.8 runs the plugin.
    private func lanWithVitaAt8(onProbe: @escaping @Sendable (String) -> Void = { _ in }) -> FakeFetcher {
        FakeFetcher { host in
            onProbe(host)
            guard host == "192.0.2.8" else { throw VitaConnectionError.refused }
            return fakeTitle("Persona")
        }
    }

    /// Expects `.unresolvedAddress` naming the MAC address, and returns its message.
    @discardableResult
    private func expectUnresolved(
        _ resolver: VitaResolver,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> String {
        let error = try await #require(throws: VitaConnectionError.self, sourceLocation: sourceLocation) {
            try await resolver.resolve(.mac(mac))
        }
        guard case .unresolvedAddress(let message) = error else {
            Issue.record("expected .unresolvedAddress, got \(error)", sourceLocation: sourceLocation)
            return ""
        }
        #expect(message.contains(mac.description), sourceLocation: sourceLocation)
        return message
    }

    @Test func returnsIPv4AddressesUnchanged() async throws {
        let fetcher = lanWithVitaAt8()
        #expect(try await resolver(fetcher: fetcher).resolve(.ipv4("192.0.2.1")) == "192.0.2.1")
        #expect(arp.lookups == 0)
        #expect(fetcher.calls.isEmpty)
    }

    @Test func usesTheARPCacheWithoutScanning() async throws {
        arp.set("192.0.2.8", for: mac)
        let fetcher = lanWithVitaAt8()
        #expect(try await resolver(fetcher: fetcher).resolve(.mac(mac)) == "192.0.2.8")
        #expect(fetcher.calls.isEmpty)
    }

    @Test func cachesTheMappingUntilInvalidated() async throws {
        arp.set("192.0.2.8", for: mac)
        let resolver = resolver(fetcher: lanWithVitaAt8())
        #expect(try await resolver.resolve(.mac(mac)) == "192.0.2.8")
        #expect(try await resolver.resolve(.mac(mac)) == "192.0.2.8")
        #expect(arp.lookups == 1)

        await resolver.invalidate(.ipv4("192.0.2.8"))
        #expect(try await resolver.resolve(.mac(mac)) == "192.0.2.8")
        #expect(arp.lookups == 1)

        await resolver.invalidate(.mac(mac))
        arp.set("192.0.2.9", for: mac)
        #expect(try await resolver.resolve(.mac(mac)) == "192.0.2.9")
        #expect(arp.lookups == 2)
    }

    @Test func scansThenRetriesTheARPCache() async throws {
        // Probing the Vita puts it in the ARP cache, even when the scanner itself can't read the table.
        let fetcher = lanWithVitaAt8 { [arp, mac] host in
            if host == "192.0.2.8" { arp.set(host, for: mac) }
        }
        #expect(try await resolver(fetcher: fetcher).resolve(.mac(mac)) == "192.0.2.8")
        #expect(fetcher.calls.sorted() == ["192.0.2.7", "192.0.2.8"])
        #expect(arp.lookups == 2)
    }

    @Test func matchesScanResultsByMAC() async throws {
        let fetcher = lanWithVitaAt8()
        let resolver = resolver(fetcher: fetcher, scanResultMACs: ["192.0.2.8": mac])
        #expect(try await resolver.resolve(.mac(mac)) == "192.0.2.8")
        #expect(try await resolver.resolve(.mac(mac)) == "192.0.2.8")
        #expect(fetcher.calls.count == 2)
    }

    @Test func ignoresVitasWithAnotherMAC() async throws {
        try await expectUnresolved(resolver(fetcher: lanWithVitaAt8(), scanResultMACs: ["192.0.2.8": otherMAC]))
    }

    @Test func scansAtMostOncePerInterval() async throws {
        let fetcher = lanWithVitaAt8()
        let resolver = resolver(
            fetcher: fetcher,
            scanResultMACs: ["192.0.2.8": otherMAC],
            minimumScanInterval: .seconds(60)
        )
        try await expectUnresolved(resolver)
        #expect(fetcher.calls.count == 2)
        let start = ContinuousClock.now
        try await expectUnresolved(resolver)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(fetcher.calls.count == 2)
        #expect(arp.lookups == 3)
    }

    @Test func scansAgainOnceTheIntervalHasPassed() async throws {
        let fetcher = lanWithVitaAt8()
        let resolver = resolver(fetcher: fetcher, scanResultMACs: ["192.0.2.8": otherMAC], minimumScanInterval: .zero)
        try await expectUnresolved(resolver)
        try await expectUnresolved(resolver)
        #expect(fetcher.calls.count == 4)
    }

    @Test func aHostWhosePollFailedIsCheckedByAScan() async throws {
        // The ARP cache still lists the Vita's old address after the router gave it a new one.
        arp.set("192.0.2.7", for: mac)
        let fetcher = lanWithVitaAt8()
        let resolver = resolver(fetcher: fetcher, scanResultMACs: ["192.0.2.8": mac])
        #expect(try await resolver.resolve(.mac(mac)) == "192.0.2.7")
        #expect(fetcher.calls.isEmpty)

        await resolver.invalidate(.mac(mac))
        #expect(try await resolver.resolve(.mac(mac)) == "192.0.2.8")
        #expect(fetcher.calls.sorted() == ["192.0.2.7", "192.0.2.8"])
        #expect(try await resolver.resolve(.mac(mac)) == "192.0.2.8")
    }

    @Test func aHostWhosePollFailedIsKeptWhenTheScanDoesntFindTheVita() async throws {
        // As while the plugin restarts: the address is right, but nothing answers on the port yet.
        arp.set("192.0.2.8", for: mac)
        let fetcher = FakeFetcher { _ in throw VitaConnectionError.refused }
        let resolver = resolver(fetcher: fetcher, minimumScanInterval: .seconds(60))
        #expect(try await resolver.resolve(.mac(mac)) == "192.0.2.8")

        await resolver.invalidate(.mac(mac))
        #expect(try await resolver.resolve(.mac(mac)) == "192.0.2.8")
        #expect(fetcher.calls.count == 2)

        // Until the next scan may run, it is used without one.
        await resolver.invalidate(.mac(mac))
        #expect(try await resolver.resolve(.mac(mac)) == "192.0.2.8")
        #expect(fetcher.calls.count == 2)
    }

    @Test func aHiddenARPCacheIsReportedWithoutScanningAgain() async throws {
        // Vitas answer the scan, but this process sees no MAC address at all.
        let fetcher = lanWithVitaAt8()
        let resolver = resolver(fetcher: fetcher, minimumScanInterval: .zero)
        let message = try await expectUnresolved(resolver)
        #expect(message.contains("ARP cache"))
        #expect(message.contains("192.0.2.8"))
        #expect(fetcher.calls.count == 2)

        #expect(try await expectUnresolved(resolver) == message)
        #expect(fetcher.calls.count == 2, "scanning again can't help")
    }

    @Test func reportsLocalNetworkDenialWithoutUsingUpTheInterval() async throws {
        let fetcher = FakeFetcher { _ in throw VitaConnectionError.localNetworkDenied }
        let resolver = resolver(fetcher: fetcher, minimumScanInterval: .seconds(60))
        await #expect(throws: VitaConnectionError.localNetworkDenied) { try await resolver.resolve(.mac(mac)) }
        let probesAfterFirstScan = fetcher.calls.count
        #expect(probesAfterFirstScan > 0)
        await #expect(throws: VitaConnectionError.localNetworkDenied) { try await resolver.resolve(.mac(mac)) }
        #expect(fetcher.calls.count > probesAfterFirstScan)
    }

    @Test func cancelledScanDoesNotUseUpTheInterval() async throws {
        let vitaIsAwake = Locked(false)
        let fetcher = FakeFetcher { host in
            while !vitaIsAwake.value {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard host == "192.0.2.8" else { throw VitaConnectionError.refused }
            return fakeTitle("Persona")
        }
        let resolver = resolver(fetcher: fetcher, scanResultMACs: ["192.0.2.8": mac])
        let firstAttempt = Task { try await resolver.resolve(.mac(mac)) }
        #expect(await eventually { fetcher.inFlight == 2 })
        firstAttempt.cancel()
        await #expect(throws: CancellationError.self) { try await firstAttempt.value }

        vitaIsAwake.withLock { $0 = true }
        #expect(try await resolver.resolve(.mac(mac)) == "192.0.2.8")
    }
}

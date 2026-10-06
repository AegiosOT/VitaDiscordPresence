import Testing
@testable import VitaKit

/// `VitaScanner` with fake fetchers. Hosts are from TEST-NET-1 (192.0.2.0/24) and nothing touches the network.
struct VitaScannerTests {
    private func scanner(
        _ fetcher: FakeFetcher,
        maxConcurrentProbes: Int = 8,
        localHosts: [String] = [],
        macAddresses: [String: MACAddress] = [:]
    ) -> VitaScanner {
        VitaScanner(
            fetcher: fetcher,
            maxConcurrentProbes: maxConcurrentProbes,
            hostLimit: 1024,
            localHosts: { localHosts },
            macAddressLookup: { macAddresses[$0] }
        )
    }

    private func testNet(_ hosts: ClosedRange<Int>) -> [String] {
        hosts.map { "192.0.2.\($0)" }
    }

    @Test func findsTheVitasAndSortsThemNumerically() async throws {
        let mac = try #require(MACAddress("b2:18:06:b6:46:f0"))
        let fetcher = FakeFetcher { host in
            switch host {
            case "192.0.2.3": throw VitaConnectionError.refused
            case "192.0.2.55": throw VitaConnectionError.invalidPacket(.badMagic(0))
            default: return fakeTitle(host)
            }
        }
        let hosts = ["192.0.2.100", "192.0.2.9", "192.0.2.3", "192.0.2.20", "192.0.2.55"]
        let found = try await scanner(fetcher, macAddresses: ["192.0.2.20": mac]).scan(hosts: hosts)
        #expect(found == [
            DiscoveredVita(ipAddress: "192.0.2.9", macAddress: nil, title: fakeTitle("192.0.2.9")),
            DiscoveredVita(ipAddress: "192.0.2.20", macAddress: mac, title: fakeTitle("192.0.2.20")),
            DiscoveredVita(ipAddress: "192.0.2.100", macAddress: nil, title: fakeTitle("192.0.2.100")),
        ])
        #expect(Set(fetcher.calls) == Set(hosts))
    }

    @Test func ignoresExpectedPerHostFailures() async throws {
        let failures: [any Error] = [
            VitaConnectionError.timedOut,
            VitaConnectionError.refused,
            VitaConnectionError.unreachable("No route to host"),
            VitaConnectionError.incompletePacket(byteCount: 3),
            VitaConnectionError.invalidPacket(.invalidIndex(-1)),
            VitaConnectionError.unresolvedAddress("bad"),
            VitaConnectionError.other("Connection reset by peer"),
        ]
        let fetcher = FakeFetcher { host in
            throw failures[Int(host.split(separator: ".").last!)! % failures.count]
        }
        #expect(try await scanner(fetcher).scan(hosts: testNet(1...20)).isEmpty)
        #expect(fetcher.calls.count == 20)
    }

    @Test func probesEachHostOnce() async throws {
        let fetcher = FakeFetcher { fakeTitle($0) }
        let hosts = ["192.0.2.1", "192.0.2.2", "192.0.2.1", "192.0.2.2", "192.0.2.1"]
        let found = try await scanner(fetcher).scan(hosts: hosts)
        #expect(found.map(\.ipAddress) == ["192.0.2.1", "192.0.2.2"])
        #expect(fetcher.calls.sorted() == ["192.0.2.1", "192.0.2.2"])
    }

    @Test func probesTheLocalCandidatesWhenGivenNoHosts() async throws {
        let fetcher = FakeFetcher { fakeTitle($0) }
        let found = try await scanner(fetcher, localHosts: ["192.0.2.7", "192.0.2.8", "192.0.2.7"]).scan()
        #expect(found.map(\.ipAddress) == ["192.0.2.7", "192.0.2.8"])
        #expect(fetcher.calls.sorted() == ["192.0.2.7", "192.0.2.8"])
    }

    @Test func emptyHostListProbesNothing() async throws {
        let fetcher = FakeFetcher { fakeTitle($0) }
        await #expect(throws: VitaConnectionError.noLocalNetwork) { try await scanner(fetcher).scan(hosts: []) }
        #expect(fetcher.calls.isEmpty)
    }

    @Test func stopsAtTheFirstLocalNetworkDenial() async throws {
        let fetcher = FakeFetcher { host in
            if host == "192.0.2.4" { throw VitaConnectionError.localNetworkDenied }
            try await Task.sleep(for: .seconds(30))
            return fakeTitle(host)
        }
        let start = ContinuousClock.now
        await #expect(throws: VitaConnectionError.localNetworkDenied) {
            try await scanner(fetcher, maxConcurrentProbes: 8).scan(hosts: testNet(1...100))
        }
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(fetcher.calls.count == 8)
        #expect(fetcher.cancellations == 7)
        #expect(fetcher.inFlight == 0)
    }

    @Test func neverRunsMoreProbesThanTheLimit() async throws {
        let gate = Locked(false)
        let fetcher = FakeFetcher { host in
            while !gate.value {
                try await Task.sleep(for: .milliseconds(2))
            }
            return fakeTitle(host)
        }
        let scan = Task { try await scanner(fetcher, maxConcurrentProbes: 5).scan(hosts: testNet(1...30)) }
        #expect(await eventually { fetcher.inFlight == 5 })
        try await Task.sleep(for: .milliseconds(50))  // room for a sixth probe to (wrongly) start
        #expect(fetcher.inFlight == 5)
        gate.withLock { $0 = true }
        #expect(try await scan.value.count == 30)
        #expect(fetcher.maxInFlight == 5)
        #expect(fetcher.calls.count == 30)
    }

    @Test func treatsANonPositiveLimitAsOne() async throws {
        let fetcher = FakeFetcher { fakeTitle($0) }
        #expect(try await scanner(fetcher, maxConcurrentProbes: 0).scan(hosts: testNet(1...5)).count == 5)
        #expect(fetcher.maxInFlight == 1)
    }

    @Test func cancellingTheScanThrowsCancellationErrorPromptly() async throws {
        let fetcher = FakeFetcher { host in
            try await Task.sleep(for: .seconds(30))
            return fakeTitle(host)
        }
        let scan = Task { try await scanner(fetcher, maxConcurrentProbes: 4).scan(hosts: testNet(1...50)) }
        #expect(await eventually { fetcher.inFlight == 4 })
        let start = ContinuousClock.now
        scan.cancel()
        await #expect(throws: CancellationError.self) { try await scan.value }
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(fetcher.calls.count == 4)
    }

    @Test func publicInitializerScansExplicitHosts() async throws {
        let fetcher = FakeFetcher { host in
            guard host == "192.0.2.42" else { throw VitaConnectionError.refused }
            return fakeTitle(host)
        }
        let found = try await VitaScanner(fetcher: fetcher, maxConcurrentProbes: 3).scan(hosts: testNet(40...44))
        #expect(found.map(\.ipAddress) == ["192.0.2.42"])
        #expect(found.first?.title == fakeTitle("192.0.2.42"))
    }
}

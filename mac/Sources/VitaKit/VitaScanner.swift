/// A Vita that answered a LAN scan.
public struct DiscoveredVita: Sendable, Hashable, Identifiable {
    public var ipAddress: String
    /// Filled in from the ARP cache when the OS exposes it. See `ARPTable`.
    public var macAddress: MACAddress?
    /// What it was running when probed.
    public var title: VitaTitle

    public var id: String { ipAddress }

    public init(ipAddress: String, macAddress: MACAddress?, title: VitaTitle) {
        self.ipAddress = ipAddress
        self.macAddress = macAddress
        self.title = title
    }
}

/// Finds Vitas running the plugin by probing port 51966 on every host of the local IPv4 subnets and keeping
/// the ones that answer with a valid packet. Probing also refreshes the ARP cache, so `macAddress` is filled
/// in when the OS exposes it.
public struct VitaScanner: Sendable {
    public let fetcher: any VitaTitleFetching
    public let maxConcurrentProbes: Int
    public let hostLimit: Int
    /// The hosts `scan()` probes when it isn't given any. Tests replace it to stay off the real network.
    let localHosts: @Sendable () -> [String]
    /// The MAC address of a host that answered. Tests replace it with a fake ARP cache.
    let macAddressLookup: @Sendable (String) -> MACAddress?

    public init(
        fetcher: any VitaTitleFetching = VitaClient(connectTimeout: .milliseconds(800), readTimeout: .seconds(2)),
        maxConcurrentProbes: Int = 48,
        hostLimit: Int = 1024
    ) {
        self.init(
            fetcher: fetcher,
            maxConcurrentProbes: maxConcurrentProbes,
            hostLimit: hostLimit,
            localHosts: {
                LocalNetwork.interfaces().flatMap { LocalNetwork.candidateHosts(on: $0, limit: hostLimit) }
            },
            macAddressLookup: { ARPTable.macAddress(forIPAddress: $0) }
        )
    }

    init(
        fetcher: any VitaTitleFetching,
        maxConcurrentProbes: Int,
        hostLimit: Int,
        localHosts: @escaping @Sendable () -> [String],
        macAddressLookup: @escaping @Sendable (String) -> MACAddress?
    ) {
        self.fetcher = fetcher
        self.maxConcurrentProbes = maxConcurrentProbes
        self.hostLimit = hostLimit
        self.localHosts = localHosts
        self.macAddressLookup = macAddressLookup
    }

    /// Probes hosts with at most `maxConcurrentProbes` connections in flight.
    /// - Parameter hosts: Hosts to probe. `nil` means every candidate host on every local interface
    ///   (`LocalNetwork`), deduplicated.
    /// - Returns: The Vitas that answered with a valid packet, sorted numerically by IP address.
    /// - Throws: `VitaConnectionError.localNetworkDenied` as soon as any probe reports it (the rest are
    ///   cancelled), or `CancellationError`. Other per-host failures are expected and ignored.
    public func scan(hosts: [String]? = nil) async throws -> [DiscoveredVita] {
        var seen = Set<String>()
        let candidates = (hosts ?? localHosts()).filter { seen.insert($0).inserted }
        let found = try await withThrowingTaskGroup(of: DiscoveredVita?.self) { group in
            var pending = candidates.makeIterator()
            for _ in 0..<max(maxConcurrentProbes, 1) {
                guard let host = pending.next() else { break }
                group.addTask { try await probe(host) }
            }
            // Throwing out of the group body cancels the probes still in flight.
            var found: [DiscoveredVita] = []
            while let result = try await group.next() {
                try Task.checkCancellation()
                if let result { found.append(result) }
                if let host = pending.next() {
                    group.addTask { try await probe(host) }
                }
            }
            return found
        }
        return found.sorted { sortKey($0) < sortKey($1) }
    }

    /// The Vita at `host`, or `nil` if nothing (or something else) answered there.
    private func probe(_ host: String) async throws -> DiscoveredVita? {
        do {
            let title = try await fetcher.fetchTitle(from: host)
            return DiscoveredVita(ipAddress: host, macAddress: macAddressLookup(host), title: title)
        } catch VitaConnectionError.localNetworkDenied {
            throw VitaConnectionError.localNetworkDenied
        } catch let error as CancellationError {
            throw error
        } catch {
            return nil
        }
    }

    private func sortKey(_ vita: DiscoveredVita) -> (UInt32, String) {
        (IPv4.parse(vita.ipAddress) ?? .max, vita.ipAddress)
    }
}

/// Turns the configured `VitaAddress` into the IPv4 address to poll.
public protocol VitaHostResolving: Sendable {
    /// The IPv4 address to poll for `address`. IPv4 addresses are returned unchanged.
    /// - Throws: `VitaConnectionError.unresolvedAddress` when a MAC can't be resolved, or
    ///   `VitaConnectionError.localNetworkDenied` if a scan was blocked.
    func resolve(_ address: VitaAddress) async throws -> String
    /// Reports that polling `address` failed, so a cached MAC → IP mapping is dropped and re-resolved on the
    /// next `resolve`. No-op for IPv4 addresses.
    func invalidate(_ address: VitaAddress) async
}

/// Resolves MAC addresses in this order: the cached mapping, the ARP cache, and finally a LAN scan matched
/// by MAC. The scan runs at most once per `minimumScanInterval`; within that interval an unresolvable MAC
/// fails fast.
///
/// - The ARP cache keeps an entry for minutes after the Vita moved to another IP address, so an ARP answer
///   that is the host whose poll just failed is checked with a scan first, when one may run. Until then,
///   and when the scan doesn't find the Vita, that host is still used.
/// - After a scan, a Vita that answered with the right MAC address wins. Scanning refreshes the ARP cache,
///   so the ARP lookup is retried next.
/// - When Vitas answer a scan but none has a MAC address, this process can't read the ARP cache (see
///   `ARPTable`), so no MAC address can ever be resolved. That is reported as an `.unresolvedAddress` that
///   names the Vitas found, and every later `resolve` fails with it right away instead of scanning again.
public actor VitaResolver: VitaHostResolving {
    private let scanner: VitaScanner
    private let arpLookup: @Sendable (MACAddress) -> String?
    private let minimumScanInterval: Duration
    private var cachedHosts: [MACAddress: String] = [:]
    /// The host whose poll failed last, per MAC address, until a scan has checked it.
    private var failedHosts: [MACAddress: String] = [:]
    private var lastScanStart: ContinuousClock.Instant?
    /// Set once a scan showed that the ARP cache is hidden from this process.
    private var hiddenARPCacheError: VitaConnectionError?

    public init(
        scanner: VitaScanner = VitaScanner(),
        arpLookup: @escaping @Sendable (MACAddress) -> String? = { ARPTable.ipAddress(for: $0) },
        minimumScanInterval: Duration = .seconds(60)
    ) {
        self.scanner = scanner
        self.arpLookup = arpLookup
        self.minimumScanInterval = minimumScanInterval
    }

    public func resolve(_ address: VitaAddress) async throws -> String {
        let mac: MACAddress
        switch address {
        case .ipv4(let host): return host
        case .mac(let address): mac = address
        }
        if let host = cachedHosts[mac] { return host }
        let now = ContinuousClock.now
        let canScan = lastScanStart.map { now - $0 >= minimumScanInterval } ?? true
        if let host = arpLookup(mac), host != failedHosts[mac] || !canScan {
            cachedHosts[mac] = host
            return host
        }
        if let hiddenARPCacheError { throw hiddenARPCacheError }
        guard canScan else { throw Self.notFound(mac) }
        // A scan that was blocked or cancelled didn't look, so it doesn't count against the interval.
        let previousScanStart = lastScanStart
        lastScanStart = now
        let found: [DiscoveredVita]
        do {
            found = try await scanner.scan()
        } catch {
            lastScanStart = previousScanStart
            throw error
        }
        failedHosts[mac] = nil
        if let host = found.first(where: { $0.macAddress == mac })?.ipAddress ?? arpLookup(mac) {
            cachedHosts[mac] = host
            return host
        }
        if !found.isEmpty, found.allSatisfy({ $0.macAddress == nil }) {
            let error = Self.hiddenARPCache(mac, found: found)
            hiddenARPCacheError = error
            throw error
        }
        throw Self.notFound(mac)
    }

    public func invalidate(_ address: VitaAddress) {
        if case .mac(let mac) = address, let host = cachedHosts.removeValue(forKey: mac) {
            failedHosts[mac] = host
        }
    }

    private static func notFound(_ mac: MACAddress) -> VitaConnectionError {
        .unresolvedAddress(
            "Couldn't find the Vita with MAC address \(mac) on this network. Try its IP address instead."
        )
    }

    private static func hiddenARPCache(_ mac: MACAddress, found: [DiscoveredVita]) -> VitaConnectionError {
        let hosts = found.map(\.ipAddress)
        let answered = hosts.count == 1
            ? "a Vita answered at \(hosts[0])"
            : "Vitas answered at \(hosts.joined(separator: ", "))"
        return .unresolvedAddress(
            "macOS doesn't let this program read the ARP cache, so it can't look up MAC address \(mac). "
                + "Use the IP address instead (\(answered))."
        )
    }
}

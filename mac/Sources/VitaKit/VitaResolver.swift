/// Turns the configured `VitaAddress` into the IPv4 address to poll.
public protocol VitaHostResolving: Sendable {
    /// The IPv4 address to poll for `address`. IPv4 addresses are returned unchanged.
    /// - Throws: `VitaConnectionError.unresolvedAddress` when a MAC can't be resolved or automatic discovery
    ///   finds no Vita (or several), or `VitaConnectionError.localNetworkDenied` if a scan was blocked.
    func resolve(_ address: VitaAddress) async throws -> String
    /// Reports that polling `address` failed: a cached MAC → IP mapping is dropped and re-resolved on the next
    /// `resolve`, and an automatically found host is checked with a scan once it has failed enough times and a
    /// scan may run. No-op for IPv4 addresses.
    func invalidate(_ address: VitaAddress) async
    /// Forgets the wait between automatic scans, so the next `resolve` of `.automatic` may scan immediately.
    /// Called when the user connects, the Mac wakes, or the network changes.
    func retryDiscovery() async
    /// Replaces the Vita `.automatic` looks for, without waiting out a failed scan. `host` is polled first.
    /// When that host is missing from a later scan, a result with `macAddress` is adopted; anything else is not.
    /// `nil` forgets that part of the identity. No-op for resolvers that only map addresses.
    func remember(host: String?, macAddress: MACAddress?) async
}

extension VitaHostResolving {
    public func remember(host: String?, macAddress: MACAddress?) async {}
}

/// Resolves automatic and MAC addresses to the host to poll. IPv4 addresses are returned unchanged.
///
/// **Automatic discovery** (`.automatic`) keeps returning the known host: `knownHost` at first (where the
/// Vita answered at the previous run), later the host a scan settled on. It scans the LAN only when there is
/// no known host, or after polling it failed (`invalidate`). Until a scan finds the Vita elsewhere, the known
/// host is still returned, also between scans while it fails. After a scan:
/// - No known host, and one Vita answered: it becomes the known host.
/// - The known host answered, alone or among others: it is kept.
/// - Other Vitas answered and the known host did not: a result with the known MAC address becomes the known
///   host, so a Vita that only changed IP address is followed. A result with a different MAC, or with no MAC,
///   is not adopted. Those results are reported with `.severalVitas` (one stranger included) and the known
///   host is kept: it may be someone else's Vita, and a sleeping Vita must not be replaced for good. The same
///   error is thrown again until the next scan.
/// - None answered: the known host is kept (the Vita is probably asleep). Without one, `.unresolvedAddress`
///   says that no Vita was found, and is thrown again until the next scan.
///
/// A known host is scanned for only after `pollsBeforeRescan` polls in a row have failed (2), so one missed
/// answer while the plugin restarts does not sweep the LAN. Scans start at least 30 s apart. While scans keep
/// settling on no host, the wait doubles after each one (30 s, 1, 2 and 4 minutes) up to 5 minutes. A success
/// resets it to 30 s: a scan that settles on a host, or a poll of the known host that didn't fail (seen as
/// `resolve` being called again without an `invalidate` in between). `retryDiscovery()` forgets the wait, so
/// connecting, waking or a network change can look again immediately. A scan that is cancelled, blocked by
/// Local Network privacy, or has no network to probe doesn't count, and its error is thrown.
///
/// **MAC addresses** resolve in this order: the cached mapping, the ARP cache, and finally a LAN scan matched
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
    /// What automatic discovery knows between calls.
    private struct Discovery {
        /// Where the Vita is polled: `knownHost`, then the last host a scan settled on.
        var host: String?
        /// The Vita to follow when `host` stops answering. `nil` until a profile has a MAC address.
        var macAddress: MACAddress?
        /// Set when polling `host` has failed `pollsBeforeRescan` times in a row, until it answers again or a
        /// scan settles on a host.
        var hostIsFailing = false
        /// Failed polls of `host` since it last answered.
        var consecutiveFailedPolls = 0
        /// `host` was handed out for a poll whose outcome isn't known yet: `invalidate` reports a failure, and
        /// another `resolve` first means that the Vita answered.
        var pollPending = false
        /// Set when the last scan left nothing to poll: no Vita and no known host, or several Vitas without the
        /// known host. Until the next scan, it is thrown instead of returning `host`.
        var error: VitaConnectionError?
        var lastScanStart: ContinuousClock.Instant?
        /// Scans in a row that settled on no host; they set the wait after `lastScanStart`.
        var failedScans = 0
        var isScanning = false

        /// The Vita answered at `host`, or a scan settled on it.
        mutating func succeed() {
            hostIsFailing = false
            consecutiveFailedPolls = 0
            failedScans = 0
            error = nil
        }

        /// Returns `host` for a poll.
        mutating func handOut(_ host: String) -> String {
            pollPending = true
            return host
        }
    }

    private let scan: @Sendable () async throws -> [DiscoveredVita]
    private let arpLookup: @Sendable (MACAddress) -> String?
    private let minimumScanInterval: Duration
    private let automaticScanDelay: Duration
    private let maximumAutomaticScanDelay: Duration
    /// Failed polls of a known host before the next resolve may scan for it.
    private let pollsBeforeRescan: Int
    private let now: @Sendable () -> ContinuousClock.Instant

    private var cachedHosts: [MACAddress: String] = [:]
    /// The host whose poll failed last, per MAC address, until a scan has checked it.
    private var failedHosts: [MACAddress: String] = [:]
    private var lastScanStart: ContinuousClock.Instant?
    /// Set once a scan showed that the ARP cache is hidden from this process.
    private var hiddenARPCacheError: VitaConnectionError?

    private var discovery: Discovery

    /// - Parameter knownHost: For `.automatic`, the host the Vita answered on last time, if known. It is polled
    ///   first, before any scan. Anything but an IPv4 address is ignored.
    /// - Parameter knownMAC: When `knownHost` is missing from a scan, the Vita with this MAC address is adopted.
    public init(
        scanner: VitaScanner = VitaScanner(),
        arpLookup: @escaping @Sendable (MACAddress) -> String? = { ARPTable.ipAddress(for: $0) },
        minimumScanInterval: Duration = .seconds(60),
        knownHost: String? = nil,
        knownMAC: MACAddress? = nil
    ) {
        self.init(
            scan: { try await scanner.scan() },
            arpLookup: arpLookup,
            minimumScanInterval: minimumScanInterval,
            knownHost: knownHost,
            knownMAC: knownMAC
        )
    }

    /// Tests replace the LAN scan with `scan` and the clock with `now`. `automaticScanDelay` is the wait
    /// between automatic scans, which doubles up to `maximumAutomaticScanDelay`.
    init(
        scan: @escaping @Sendable () async throws -> [DiscoveredVita],
        arpLookup: @escaping @Sendable (MACAddress) -> String? = { ARPTable.ipAddress(for: $0) },
        minimumScanInterval: Duration = .seconds(60),
        knownHost: String? = nil,
        knownMAC: MACAddress? = nil,
        automaticScanDelay: Duration = .seconds(30),
        maximumAutomaticScanDelay: Duration = .seconds(300),
        pollsBeforeRescan: Int = 2,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.scan = scan
        self.arpLookup = arpLookup
        self.minimumScanInterval = minimumScanInterval
        self.automaticScanDelay = automaticScanDelay
        self.maximumAutomaticScanDelay = maximumAutomaticScanDelay
        self.pollsBeforeRescan = max(pollsBeforeRescan, 1)
        self.now = now
        discovery = Discovery(
            host: knownHost.flatMap(IPv4.parse).map(IPv4.string),
            macAddress: knownMAC
        )
    }

    /// Points automatic discovery at another saved Vita. The next `resolve` of `.automatic` polls `host`
    /// immediately, and a later scan may follow `macAddress` when that host is gone.
    public func remember(host: String?, macAddress: MACAddress?) async {
        discovery.host = host.flatMap(IPv4.parse).map(IPv4.string)
        discovery.macAddress = macAddress
        discovery.hostIsFailing = false
        discovery.consecutiveFailedPolls = 0
        discovery.pollPending = false
        discovery.error = nil
        discovery.failedScans = 0
        discovery.lastScanStart = nil
    }

    /// Where `.automatic` polls: `knownHost`, or the last host a scan settled on.
    var automaticHost: String? { discovery.host }

    public func resolve(_ address: VitaAddress) async throws -> String {
        switch address {
        case .automatic: return try await resolveAutomatically()
        case .ipv4(let host): return host
        case .mac(let mac): return try await resolve(mac)
        }
    }

    public func invalidate(_ address: VitaAddress) {
        switch address {
        case .automatic:
            discovery.pollPending = false
            guard discovery.host != nil else { break }
            discovery.consecutiveFailedPolls += 1
            if discovery.consecutiveFailedPolls >= pollsBeforeRescan {
                discovery.hostIsFailing = true
            }
        case .mac(let mac):
            if let host = cachedHosts.removeValue(forKey: mac) { failedHosts[mac] = host }
        case .ipv4:
            break
        }
    }

    public func retryDiscovery() {
        discovery.lastScanStart = nil
        discovery.failedScans = 0
        discovery.error = nil
    }

    // MARK: Automatic discovery

    private func resolveAutomatically() async throws -> String {
        if discovery.pollPending {
            // Nothing reported the host handed out last time as failing, so the Vita answered there.
            discovery.succeed()
            discovery.pollPending = false
        }
        if let host = discovery.host, !discovery.hostIsFailing {
            return discovery.handOut(host)
        }
        let now = self.now()
        guard mayScanAutomatically(at: now) else {
            if let error = discovery.error { throw error }
            if let host = discovery.host { return discovery.handOut(host) }
            throw Self.noVitaFound  // only while another call's scan is still running
        }
        let previousScanStart = discovery.lastScanStart
        discovery.lastScanStart = now
        discovery.isScanning = true
        defer { discovery.isScanning = false }
        let found: [DiscoveredVita]
        do {
            found = try await scan()
        } catch {
            // A scan that was blocked, cancelled or had no network to probe didn't look, so it doesn't count.
            discovery.lastScanStart = previousScanStart
            throw error
        }
        let hosts = found.map(\.ipAddress)
        if let known = discovery.host, hosts.contains(known) {
            discovery.host = known
            discovery.succeed()
            return discovery.handOut(known)
        }
        if let mac = discovery.macAddress, let match = found.first(where: { $0.macAddress == mac }) {
            discovery.host = match.ipAddress
            discovery.succeed()
            return discovery.handOut(match.ipAddress)
        }
        if discovery.host == nil, hosts.count == 1, let only = hosts.first {
            discovery.host = only
            discovery.succeed()
            return discovery.handOut(only)
        }
        discovery.failedScans += 1
        if hosts.isEmpty, let host = discovery.host {
            // The Vita is probably asleep: keep polling where it was.
            discovery.error = nil
            return discovery.handOut(host)
        }
        let error: VitaConnectionError = hosts.isEmpty ? Self.noVitaFound : .severalVitas(hosts)
        discovery.error = error
        throw error
    }

    /// Whether an automatic scan may start at `now`: none is running, and the wait after the last one is over.
    private func mayScanAutomatically(at now: ContinuousClock.Instant) -> Bool {
        guard !discovery.isScanning else { return false }
        guard let lastScanStart = discovery.lastScanStart else { return true }
        let doublings = min(max(discovery.failedScans - 1, 0), 16)
        return now - lastScanStart >= min(automaticScanDelay * (1 << doublings), maximumAutomaticScanDelay)
    }

    private static let noVitaFound = VitaConnectionError.unresolvedAddress(
        "No Vita found on this network. Is it awake, on the same Wi-Fi, and running the VitaPresence plugin?"
    )

    // MARK: MAC addresses

    private func resolve(_ mac: MACAddress) async throws -> String {
        if let host = cachedHosts[mac] { return host }
        let now = self.now()
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
            found = try await scan()
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

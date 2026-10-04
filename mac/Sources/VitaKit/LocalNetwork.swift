import Darwin

/// A local IPv4 network interface, such as Wi-Fi `en0`.
public struct LocalIPv4Interface: Sendable, Hashable {
    /// BSD name, such as `en0`.
    public var name: String
    /// The interface's own address, such as `192.168.1.20`.
    public var address: String
    /// Subnet mask, such as `255.255.255.0`.
    public var netmask: String

    public init(name: String, address: String, netmask: String) {
        self.name = name
        self.address = address
        self.netmask = netmask
    }
}

/// Enumerates the LAN subnets the Vita could be on.
public enum LocalNetwork {
    private static let excludedNamePrefixes = ["utun", "ipsec", "ppp", "awdl", "llw", "nan"]

    /// IPv4 interfaces (via `getifaddrs`) that are up, running and broadcast-capable. Excludes loopback,
    /// point-to-point and VPN interfaces (`utun*`, `ipsec*`, `ppp*`), AWDL and Wi-Fi Aware interfaces
    /// (`awdl*`, `llw*`, `nan*`), and link-local 169.254/16 addresses.
    public static func interfaces() -> [LocalIPv4Interface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        return sequence(first: first, next: { $0.pointee.ifa_next }).compactMap { interface(from: $0.pointee) }
    }

    /// Hosts to probe on `interface`: every host address in its subnet except the network address, the
    /// broadcast address and the interface's own address, in ascending order. Subnets with more than `limit`
    /// hosts are narrowed to the /24 containing the interface address.
    public static func candidateHosts(on interface: LocalIPv4Interface, limit: Int = 1024) -> [String] {
        guard let address = IPv4.parse(interface.address), let netmask = IPv4.parse(interface.netmask) else {
            return []
        }
        return hostAddresses(address: address, netmask: netmask, limit: limit).map(IPv4.string)
    }

    /// Pure helper behind `candidateHosts`, with addresses as host-byte-order integers. For /31 and /32
    /// masks it returns no hosts.
    static func hostAddresses(address: UInt32, netmask: UInt32, limit: Int) -> [UInt32] {
        var prefixLength = (~netmask).leadingZeroBitCount
        guard prefixLength <= 30 else { return [] }
        if (1 << (32 - prefixLength)) - 2 > limit {
            prefixLength = max(prefixLength, 24)
        }
        let mask = UInt32.max << (32 - prefixLength)
        let network = address & mask
        let broadcast = network | ~mask
        return ((network + 1)..<broadcast).filter { $0 != address }
    }

    private static func interface(from entry: ifaddrs) -> LocalIPv4Interface? {
        let flags = Int32(bitPattern: entry.ifa_flags)
        let required = IFF_UP | IFF_RUNNING | IFF_BROADCAST
        guard flags & required == required, flags & (IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
              let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
              let netmask = entry.ifa_netmask
        else { return nil }
        let name = String(cString: entry.ifa_name)
        let value = ipv4Address(in: address)
        guard !excludedNamePrefixes.contains(where: name.hasPrefix), value >> 16 != 0xA9FE else { return nil }
        return LocalIPv4Interface(
            name: name,
            address: IPv4.string(value),
            netmask: IPv4.string(ipv4Address(in: netmask))
        )
    }

    /// The IPv4 address in `sockaddr`, in host byte order. Netmasks come compacted (`sa_len` 7 for a /24,
    /// trailing zero bytes left out), so bytes past `sa_len` count as zero instead of being read.
    private static func ipv4Address(in sockaddr: UnsafeMutablePointer<sockaddr>) -> UInt32 {
        let length = Int(sockaddr.pointee.sa_len)
        let start = MemoryLayout<sockaddr_in>.offset(of: \.sin_addr)!
        let raw = UnsafeRawPointer(sockaddr)
        return (start..<(start + 4)).reduce(0) { value, offset in
            value << 8 | UInt32(offset < length ? raw.load(fromByteOffset: offset, as: UInt8.self) : 0)
        }
    }
}

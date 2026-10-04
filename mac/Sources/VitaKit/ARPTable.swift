import Darwin

/// One resolved entry of the kernel's IPv4 ARP cache.
public struct ARPEntry: Sendable, Hashable {
    public var ipAddress: String
    public var macAddress: MACAddress

    public init(ipAddress: String, macAddress: MACAddress) {
        self.ipAddress = ipAddress
        self.macAddress = macAddress
    }
}

/// Best-effort reader for the kernel's IPv4 ARP cache, using the same sysctl as `arp -an`.
///
/// - Important: The cache only holds hosts this Mac exchanged traffic with in the last ~20 minutes. On
///   macOS 27 the kernel also returns an empty table to processes that aren't signed with a reverse-DNS
///   identifier, such as binaries run with `swift run`. Treat an empty result as "unknown", never as
///   "not on the network".
public enum ARPTable {
    private static let headerLength = MemoryLayout<rt_msghdr>.size
    private static let linkFamilyOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_family)!
    private static let linkNameLengthOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_nlen)!
    private static let linkAddressLengthOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_alen)!
    private static let linkDataOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)!

    /// All complete entries (those with a 6-byte link-layer address). Returns `[]` on any error.
    public static func entries() -> [ARPEntry] {
        routingMessages().map { parse(routingMessages: $0) } ?? []
    }

    /// The IPv4 address currently cached for `mac`, if any.
    public static func ipAddress(for mac: MACAddress) -> String? {
        entries().first { $0.macAddress == mac }?.ipAddress
    }

    /// The MAC address currently cached for `ipAddress`, if any.
    public static func macAddress(forIPAddress ipAddress: String) -> MACAddress? {
        entries().first { $0.ipAddress == ipAddress }?.macAddress
    }

    /// Parses the buffer returned by sysctl `{CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO}`.
    /// The buffer is a sequence of records, each `rtm_msglen` bytes long: an `rt_msghdr`, a
    /// `sockaddr_inarp`, then a `sockaddr_dl` at the next 4-byte boundary. The MAC starts at
    /// `sdl_data + sdl_nlen` and is `sdl_alen` bytes long. Records without a 6-byte address (incomplete
    /// entries) and malformed or truncated records are skipped without crashing.
    static func parse(routingMessages: [UInt8]) -> [ARPEntry] {
        routingMessages.withUnsafeBytes { buffer in
            var entries: [ARPEntry] = []
            var offset = 0
            while offset + headerLength <= buffer.count {
                let header = buffer.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self)
                let length = Int(header.rtm_msglen)
                // A zero length would never advance, and a record running past the end is cut off.
                guard length > 0, offset + length <= buffer.count else { break }
                let record = UnsafeRawBufferPointer(rebasing: buffer[offset..<(offset + length)])
                if Int32(header.rtm_version) == RTM_VERSION, let entry = entry(in: record) {
                    entries.append(entry)
                }
                offset += length
            }
            return entries
        }
    }

    /// The entry in one record, or `nil` when it is incomplete or malformed. Every read stays inside `record`.
    private static func entry(in record: UnsafeRawBufferPointer) -> ARPEntry? {
        guard headerLength + MemoryLayout<sockaddr_inarp>.size <= record.count else { return nil }
        let destination = record.loadUnaligned(fromByteOffset: headerLength, as: sockaddr_inarp.self)
        guard destination.sin_family == sa_family_t(AF_INET) else { return nil }
        let link = headerLength + roundedUpSockaddrLength(Int(destination.sin_len))
        guard link + linkDataOffset <= record.count,
              record[link + linkFamilyOffset] == AF_LINK,
              record[link + linkAddressLengthOffset] == 6  // 0 for incomplete entries
        else { return nil }
        let macStart = link + linkDataOffset + Int(record[link + linkNameLengthOffset])
        guard macStart + 6 <= record.count,
              let mac = MACAddress(bytes: record[macStart..<(macStart + 6)])
        else { return nil }
        return ARPEntry(ipAddress: IPv4.string(UInt32(bigEndian: destination.sin_addr.s_addr)), macAddress: mac)
    }

    /// `SA_SIZE` from `route.h`: socket addresses in routing messages are padded to 4-byte multiples.
    private static func roundedUpSockaddrLength(_ length: Int) -> Int {
        length > 0 ? (length + 3) & ~3 : 4
    }

    /// The raw ARP dump, or `nil` on error. Entries can appear between sizing the buffer and filling it,
    /// which fails with ENOMEM, so that case is retried with a fresh size.
    private static func routingMessages() -> [UInt8]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        for _ in 0..<5 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return nil }
            guard size > 0 else { return [] }
            size += size / 8
            var buffer = [UInt8](repeating: 0, count: size)
            if sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 {
                return Array(buffer.prefix(size))
            }
            guard errno == ENOMEM else { return nil }
        }
        return nil
    }
}

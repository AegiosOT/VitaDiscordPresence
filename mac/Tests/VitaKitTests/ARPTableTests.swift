import Darwin
import Testing
@testable import VitaKit

/// One record as the ARP sysctl returns it: an `rt_msghdr`, a `sockaddr_inarp`, then a `sockaddr_dl` whose
/// data holds the interface name followed by the link-layer address (empty for incomplete entries).
private func arpRecord(
    ip: [UInt8],
    mac: [UInt8],
    interface: String = "en0",
    version: Int32 = RTM_VERSION,
    family: Int32 = AF_INET
) -> [UInt8] {
    var destination = sockaddr_inarp()
    destination.sin_len = UInt8(MemoryLayout<sockaddr_inarp>.size)
    destination.sin_family = sa_family_t(family)
    destination.sin_addr.s_addr = ip.withUnsafeBytes { $0.loadUnaligned(as: in_addr_t.self) }

    let name = Array(interface.utf8)
    let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)!
    let linkLength = max(MemoryLayout<sockaddr_dl>.size, dataOffset + name.count + mac.count)
    var link = [UInt8](repeating: 0, count: linkLength)
    link[MemoryLayout<sockaddr_dl>.offset(of: \.sdl_len)!] = UInt8(link.count)
    link[MemoryLayout<sockaddr_dl>.offset(of: \.sdl_family)!] = UInt8(AF_LINK)
    link[MemoryLayout<sockaddr_dl>.offset(of: \.sdl_index)!] = 4
    link[MemoryLayout<sockaddr_dl>.offset(of: \.sdl_type)!] = 6  // IFT_ETHER
    link[MemoryLayout<sockaddr_dl>.offset(of: \.sdl_nlen)!] = UInt8(name.count)
    link[MemoryLayout<sockaddr_dl>.offset(of: \.sdl_alen)!] = UInt8(mac.count)
    link.replaceSubrange(dataOffset..<(dataOffset + name.count + mac.count), with: name + mac)
    link += [UInt8](repeating: 0, count: (4 - link.count % 4) % 4)

    var header = rt_msghdr()
    header.rtm_msglen = UInt16(MemoryLayout<rt_msghdr>.size + MemoryLayout<sockaddr_inarp>.size + link.count)
    header.rtm_version = UInt8(version)
    header.rtm_type = UInt8(RTM_GET)
    header.rtm_flags = RTF_UP | RTF_HOST | RTF_LLINFO
    header.rtm_addrs = RTA_DST | RTA_GATEWAY
    return withUnsafeBytes(of: header) { Array($0) } + withUnsafeBytes(of: destination) { Array($0) } + link
}

/// Overwrites the record length of the record starting at `offset`.
private func setMessageLength(_ length: UInt16, in buffer: inout [UInt8], at offset: Int = 0) {
    withUnsafeBytes(of: length) { buffer.replaceSubrange(offset..<(offset + 2), with: $0) }
}

/// A deterministic random number generator (SplitMix64) for the fuzz test.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct ARPTableParsingTests {
    let vitaMAC: [UInt8] = [0xB2, 0x18, 0x06, 0xB6, 0x46, 0xF0]
    let routerMAC: [UInt8] = [0x54, 0xB7, 0xBD, 0xE0, 0x3F, 0x71]

    private func entry(_ ip: String, _ mac: [UInt8]) -> ARPEntry {
        ARPEntry(ipAddress: ip, macAddress: MACAddress(bytes: mac)!)
    }

    @Test func recordLayoutMatchesTheKernel() {
        // rt_msghdr 92 + sockaddr_inarp 16 + sockaddr_dl 20, as `arp -an` sees them.
        #expect(arpRecord(ip: [192, 168, 1, 152], mac: vitaMAC).count == 128)
    }

    @Test func parsesACompleteEntry() {
        let entries = ARPTable.parse(routingMessages: arpRecord(ip: [192, 168, 1, 152], mac: vitaMAC))
        #expect(entries == [entry("192.168.1.152", vitaMAC)])
        #expect(entries.first?.macAddress.description == "b2:18:06:b6:46:f0")
    }

    @Test func skipsIncompleteEntries() {
        #expect(ARPTable.parse(routingMessages: arpRecord(ip: [192, 168, 1, 253], mac: [])).isEmpty)
    }

    @Test func parsesSeveralRecords() {
        let buffer = arpRecord(ip: [192, 168, 1, 1], mac: routerMAC)
            + arpRecord(ip: [192, 168, 1, 253], mac: [])
            + arpRecord(ip: [192, 168, 64, 2], mac: vitaMAC, interface: "bridge100")
            + arpRecord(ip: [10, 0, 0, 7], mac: vitaMAC, interface: "")
        #expect(ARPTable.parse(routingMessages: buffer) == [
            entry("192.168.1.1", routerMAC),
            entry("192.168.64.2", vitaMAC),
            entry("10.0.0.7", vitaMAC),
        ])
    }

    @Test func skipsRecordsThatAreNotIPv4EthernetEntries() {
        let buffer = arpRecord(ip: [192, 168, 1, 2], mac: vitaMAC, version: RTM_VERSION + 1)
            + arpRecord(ip: [192, 168, 1, 3], mac: vitaMAC, family: AF_INET6)
            + arpRecord(ip: [192, 168, 1, 4], mac: vitaMAC + [0, 0])  // 8-byte link address
            + arpRecord(ip: [192, 168, 1, 5], mac: vitaMAC)
        #expect(ARPTable.parse(routingMessages: buffer) == [entry("192.168.1.5", vitaMAC)])
    }

    @Test(arguments: [1, 50, 92, 100, 127])
    func stopsAtATruncatedRecord(keptBytes: Int) {
        let complete = arpRecord(ip: [192, 168, 1, 1], mac: routerMAC)
        let buffer = complete + arpRecord(ip: [192, 168, 1, 152], mac: vitaMAC).prefix(keptBytes)
        #expect(ARPTable.parse(routingMessages: buffer) == [entry("192.168.1.1", routerMAC)])
    }

    @Test func stopsAtAZeroLengthRecord() {
        var stuck = arpRecord(ip: [192, 168, 1, 152], mac: vitaMAC)
        setMessageLength(0, in: &stuck)
        let buffer = arpRecord(ip: [192, 168, 1, 1], mac: routerMAC)
            + stuck
            + arpRecord(ip: [192, 168, 1, 7], mac: vitaMAC)
        #expect(ARPTable.parse(routingMessages: buffer) == [entry("192.168.1.1", routerMAC)])
    }

    @Test func skipsARecordTooShortForItsAddresses() {
        // The length covers the header and part of the sockaddr_inarp only; the next record is still read.
        var short = arpRecord(ip: [192, 168, 1, 152], mac: vitaMAC)
        let shortLength = MemoryLayout<rt_msghdr>.size + 8
        setMessageLength(UInt16(shortLength), in: &short)
        let buffer = Array(short.prefix(shortLength)) + arpRecord(ip: [192, 168, 1, 1], mac: routerMAC)
        #expect(ARPTable.parse(routingMessages: buffer) == [entry("192.168.1.1", routerMAC)])
    }

    @Test func skipsALinkAddressThatRunsPastItsRecord() {
        var record = arpRecord(ip: [192, 168, 1, 152], mac: vitaMAC)
        let nameLengthOffset = MemoryLayout<rt_msghdr>.size + MemoryLayout<sockaddr_inarp>.size
            + MemoryLayout<sockaddr_dl>.offset(of: \.sdl_nlen)!
        record[nameLengthOffset] = 200
        #expect(ARPTable.parse(routingMessages: record + arpRecord(ip: [192, 168, 1, 1], mac: routerMAC)) == [
            entry("192.168.1.1", routerMAC)
        ])
    }

    @Test func handlesAnEmptyBuffer() {
        #expect(ARPTable.parse(routingMessages: []).isEmpty)
    }

    @Test func neverCrashesOnCorruptedBuffers() {
        var random = SplitMix64(state: 0x5EED)
        let valid = arpRecord(ip: [192, 168, 1, 1], mac: routerMAC)
            + arpRecord(ip: [192, 168, 1, 253], mac: [])
            + arpRecord(ip: [192, 168, 1, 152], mac: vitaMAC, interface: "bridge100")
        for _ in 0..<2_000 {
            var buffer = valid
            for _ in 0..<Int.random(in: 1...8, using: &random) {
                buffer[Int.random(in: 0..<buffer.count, using: &random)] = UInt8.random(in: 0...255, using: &random)
            }
            buffer = Array(buffer.prefix(Int.random(in: 0...buffer.count, using: &random)))
            for entry in ARPTable.parse(routingMessages: buffer) {
                #expect(IPv4.parse(entry.ipAddress) != nil)
            }
        }
        for _ in 0..<500 {
            let count = Int.random(in: 0...600, using: &random)
            let noise = (0..<count).map { _ in UInt8.random(in: 0...255, using: &random) }
            _ = ARPTable.parse(routingMessages: noise)
        }
    }
}

struct ARPTableLiveTests {
    @Test func readsTheKernelTableWithoutCrashing() {
        // Unsigned test binaries get an empty table on macOS 27; any entries must still be well formed.
        let entries = ARPTable.entries()
        for entry in entries {
            #expect(IPv4.parse(entry.ipAddress) != nil)
        }
        if let first = entries.first {
            #expect(ARPTable.ipAddress(for: first.macAddress) != nil)
            #expect(ARPTable.macAddress(forIPAddress: first.ipAddress) != nil)
        }
    }
}

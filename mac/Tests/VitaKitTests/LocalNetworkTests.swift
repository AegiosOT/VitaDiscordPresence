import Testing
@testable import VitaKit

struct LocalNetworkTests {
    /// `hostAddresses` with dotted-quad strings in and out.
    private func hosts(_ address: String, _ netmask: String, limit: Int = 1024) -> [String] {
        LocalNetwork.hostAddresses(address: IPv4.parse(address)!, netmask: IPv4.parse(netmask)!, limit: limit)
            .map(IPv4.string)
    }

    @Test func slash24ExcludesNetworkBroadcastAndOwnAddress() {
        let result = hosts("192.168.1.20", "255.255.255.0")
        #expect(result.count == 253)
        #expect(result.first == "192.168.1.1")
        #expect(result.last == "192.168.1.254")
        #expect(!result.contains("192.168.1.20"))
        #expect(result == (1...254).filter { $0 != 20 }.map { "192.168.1.\($0)" })
    }

    @Test func slash23SpansTwoThirdOctets() {
        let result = hosts("10.0.4.7", "255.255.254.0")
        #expect(result.count == 509)
        #expect(result.first == "10.0.4.1")
        #expect(result.last == "10.0.5.254")
        #expect(result.contains("10.0.4.255"))
        #expect(result.contains("10.0.5.0"))
        #expect(!result.contains("10.0.4.7"))
    }

    @Test func slash30() {
        #expect(hosts("192.168.1.5", "255.255.255.252") == ["192.168.1.6"])
        #expect(hosts("192.168.1.9", "255.255.255.252") == ["192.168.1.10"])
    }

    @Test(arguments: ["255.255.255.254", "255.255.255.255"])
    func slash31AndSlash32HaveNoHosts(netmask: String) {
        #expect(hosts("192.168.1.5", netmask).isEmpty)
    }

    @Test func largeSubnetIsNarrowedToTheSlash24OfTheInterface() {
        let result = hosts("172.16.5.9", "255.255.0.0")
        #expect(result == (1...254).filter { $0 != 9 }.map { "172.16.5.\($0)" })
    }

    @Test func limitDecidesWhetherToNarrow() {
        // A /22 has 1022 hosts.
        #expect(hosts("10.1.6.10", "255.255.252.0", limit: 1024).count == 1021)
        #expect(hosts("10.1.6.10", "255.255.252.0", limit: 1022).count == 1021)
        let narrowed = hosts("10.1.6.10", "255.255.252.0", limit: 1021)
        #expect(narrowed.count == 253)
        #expect(narrowed.first == "10.1.6.1")
        #expect(narrowed.last == "10.1.6.254")
    }

    @Test func narrowingNeverWidensASmallSubnet() {
        // A /25 has 126 hosts: over the limit, but already smaller than a /24.
        let result = hosts("192.168.1.130", "255.255.255.128", limit: 100)
        #expect(result.count == 125)
        #expect(result.first == "192.168.1.129")
        #expect(result.last == "192.168.1.254")
    }

    @Test func zeroNetmaskIsNarrowedWithoutOverflow() {
        #expect(hosts("10.1.2.3", "0.0.0.0").count == 253)
    }

    @Test func candidateHostsUsesTheInterfaceAddressAndNetmask() {
        let interface = LocalIPv4Interface(name: "en0", address: "192.168.1.21", netmask: "255.255.255.248")
        #expect(LocalNetwork.candidateHosts(on: interface) == [
            "192.168.1.17", "192.168.1.18", "192.168.1.19", "192.168.1.20", "192.168.1.22",
        ])
        let wide = LocalIPv4Interface(name: "en0", address: "10.20.30.40", netmask: "255.255.0.0")
        #expect(LocalNetwork.candidateHosts(on: wide).count == 253)
        #expect(LocalNetwork.candidateHosts(on: wide, limit: 65_534).count == 65_533)
    }

    @Test func candidateHostsIgnoresUnusableInterfaces() {
        let badAddress = LocalIPv4Interface(name: "en0", address: "x", netmask: "255.255.255.0")
        let badNetmask = LocalIPv4Interface(name: "en0", address: "10.0.0.2", netmask: "/24")
        #expect(LocalNetwork.candidateHosts(on: badAddress).isEmpty)
        #expect(LocalNetwork.candidateHosts(on: badNetmask).isEmpty)
    }

    @Test func interfacesAreBroadcastCapableLANInterfaces() {
        // Reads the local interface list only; nothing is sent.
        for interface in LocalNetwork.interfaces() {
            #expect(IPv4.parse(interface.address) != nil)
            #expect(IPv4.parse(interface.netmask) != nil)
            #expect(!interface.address.hasPrefix("169.254."))
            #expect(!interface.address.hasPrefix("127."))
            #expect(!["lo", "utun", "ipsec", "ppp", "awdl", "llw", "nan"].contains(where: interface.name.hasPrefix))
        }
    }
}

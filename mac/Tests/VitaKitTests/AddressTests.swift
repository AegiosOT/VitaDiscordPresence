import Foundation
import Testing
@testable import VitaKit

struct MACAddressTests {
    @Test(arguments: [
        "a4:5e:60:01:02:03",
        "A4:5E:60:01:02:03",
        "a4:5e:60:1:2:3",
        "A4-5E-60-01-02-03",
        "a4-5e-60-01-02-03",
        "a45e.6001.0203",
        "A45E.6001.0203",
        "a45e60010203",
        "A45E60010203",
        "  a4:5e:60:01:02:03\n",
    ])
    func parsesSupportedFormats(input: String) {
        #expect(MACAddress(input)?.bytes == [0xA4, 0x5E, 0x60, 0x01, 0x02, 0x03])
    }

    @Test func parsesMacOSArpOutputWithoutLeadingZeros() {
        #expect(MACAddress("b2:18:6:b6:46:f0")?.description == "b2:18:06:b6:46:f0")
        #expect(MACAddress("1:0:5e:0:0:fb")?.description == "01:00:5e:00:00:fb")
    }

    @Test(arguments: [
        "",
        "   ",
        "a4:5e:60:01:02",
        "a4:5e:60:01:02:03:04",
        "a4:5e:60-01-02-03",
        "a4-5e-60-01-02.03",
        "a4:5e:60:01:02:0g",
        "a4:5e:60:001:02:03",
        "a4::60:01:02:03",
        "a4:5e:60:01:02:03:",
        ":a4:5e:60:01:02:03",
        "a4-5e-60-1-2-3",
        "a45e.6001.020",
        "a45e.6001.0203.0405",
        "a45e:6001:0203",
        "a45e6001020",
        "a45e600102030",
        "+4:5e:60:01:02:03",
        "a4 5e 60 01 02 03",
        "a4:5e:60:01:02:03 x",
        "１２:34:56:78:9a:bc",
        "192.168.1.20",
        "0xa45e60010203",
    ])
    func rejectsEverythingElse(input: String) {
        #expect(MACAddress(input) == nil)
    }

    @Test func createsFromExactlySixBytes() {
        #expect(MACAddress(bytes: [1, 2, 3, 4, 5, 6])?.description == "01:02:03:04:05:06")
        let sequence = stride(from: UInt8(0x0E), through: 0x13, by: 1)
        #expect(MACAddress(bytes: sequence)?.description == "0e:0f:10:11:12:13")
        #expect(MACAddress(bytes: [1, 2, 3, 4, 5]) == nil)
        #expect(MACAddress(bytes: [1, 2, 3, 4, 5, 6, 7]) == nil)
        #expect(MACAddress(bytes: []) == nil)
    }

    @Test func equalAddressesHashTheSame() throws {
        let a = try #require(MACAddress("A4-5E-60-01-02-03"))
        let b = try #require(MACAddress("a4:5e:60:1:2:3"))
        #expect(a == b)
        #expect(Set([a, b]).count == 1)
    }

    @Test func encodesAsTheCanonicalString() throws {
        let mac = try #require(MACAddress("A4-5E-60-01-02-03"))
        let json = try JSONEncoder().encode([mac])
        #expect(String(decoding: json, as: UTF8.self) == #"["a4:5e:60:01:02:03"]"#)
    }

    @Test func decodesAnyAcceptedFormat() throws {
        let mac = try #require(MACAddress("a4:5e:60:01:02:03"))
        let json = Data(#"["a45e.6001.0203","A4-5E-60-01-02-03","a4:5e:60:1:2:3"]"#.utf8)
        #expect(try JSONDecoder().decode([MACAddress].self, from: json) == [mac, mac, mac])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([MACAddress].self, from: Data(#"["a4:5e:60"]"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([MACAddress].self, from: Data("[42]".utf8))
        }
    }
}

struct VitaAddressTests {
    @Test(arguments: [
        ("192.168.1.20", "192.168.1.20"),
        ("10.0.0.1", "10.0.0.1"),
        ("0.0.0.0", "0.0.0.0"),
        ("255.255.255.255", "255.255.255.255"),
        (" 172.16.5.9\t\n", "172.16.5.9"),
    ])
    func parsesIPv4(input: String, normalized: String) {
        #expect(VitaAddress(input) == .ipv4(normalized))
    }

    @Test(arguments: [
        "a4:5e:60:01:02:03",
        "A4-5E-60-01-02-03",
        "a45e.6001.0203",
        "a45e60010203",
        " a4:5e:60:1:2:3 ",
    ])
    func parsesMACAddresses(input: String) throws {
        #expect(VitaAddress(input) == .mac(try #require(MACAddress(bytes: [0xA4, 0x5E, 0x60, 1, 2, 3]))))
    }

    @Test(arguments: [
        "192.168.001.1",
        "01.2.3.4",
        "1.2.3.04",
        "00.1.2.3",
        "192.168.1",
        "192.168.1.256",
        "1.2.3.4.5",
        "1..2.3",
        "192.168.1.20:51966",
        "vita.local",
        "localhost",
        "0x7f.0.0.1",
        "127.1",
        "1.2.3.-4",
        "1.2.3.+4",
        "1.2.3. 4",
        "1.2.3.4 5",
        "１.２.３.４",
        "::1",
        "fe80::1",
        "1.2.3.4\u{0}",
        "1.2.3.4\u{0}junk",
        "autodetect",
    ])
    func rejectsInvalidInput(input: String) {
        #expect(VitaAddress(input) == nil)
    }

    @Test(arguments: ["", "   ", "\n", "auto", "Automatic", " AUTO "])
    func emptyOrAutoMeansAutomatic(input: String) {
        #expect(VitaAddress(input) == .automatic)
        #expect(VitaAddress(input)?.description == "automatic")
    }

    @Test func descriptionIsTheNormalizedAddress() {
        #expect(VitaAddress(" 192.168.1.20 ")?.description == "192.168.1.20")
        #expect(VitaAddress("A4-5E-60-01-02-03")?.description == "a4:5e:60:01:02:03")
    }
}

import Darwin

/// Strict dotted-quad IPv4 parsing and formatting shared by the VitaKit types.
enum IPv4 {
    /// Parses exactly four decimal octets 0-255 without leading zeros, such as `192.168.1.20`, into a
    /// host-byte-order address. Ports, hostnames and anything else return `nil`.
    static func parse(_ string: String) -> UInt32? {
        var address = in_addr()
        guard !string.utf8.contains(0),  // inet_pton would stop reading at an embedded NUL
              inet_pton(AF_INET, string, &address) == 1,
              // Darwin's inet_pton accepts leading zeros ("192.168.001.1"), which other tools read as octal.
              !string.split(separator: ".").contains(where: { $0.count > 1 && $0.hasPrefix("0") })
        else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    /// Formats a host-byte-order address as a dotted quad.
    static func string(_ address: UInt32) -> String {
        "\(address >> 24).\(address >> 16 & 0xFF).\(address >> 8 & 0xFF).\(address & 0xFF)"
    }
}

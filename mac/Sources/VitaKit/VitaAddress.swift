/// How the user identifies their Vita: found automatically, or by IPv4 or MAC address.
public enum VitaAddress: Sendable, Hashable, CustomStringConvertible {
    /// Find the Vita by scanning the local network for the plugin, and remember where it was.
    case automatic
    /// A normalized IPv4 dotted quad, such as `192.168.1.20`.
    case ipv4(String)
    /// A hardware address, resolved to an IP at poll time.
    case mac(MACAddress)

    /// Parses user input, ignoring surrounding whitespace. Empty input, `auto` and `automatic` (any case)
    /// become `.automatic`. A strict dotted-quad IPv4 address (validated with `inet_pton`, no leading zeros,
    /// ports or hostnames) becomes `.ipv4`. Anything `MACAddress` accepts becomes `.mac`. Everything else
    /// returns `nil`.
    public init?(_ input: String) {
        let text = String(input.trimmingWhitespace())
        if text.isEmpty || ["auto", "automatic"].contains(text.lowercased()) {
            self = .automatic
        } else if let address = IPv4.parse(text) {
            self = .ipv4(IPv4.string(address))
        } else if let mac = MACAddress(text) {
            self = .mac(mac)
        } else {
            return nil
        }
    }

    /// `automatic`, the IPv4 string, or the canonical MAC string.
    public var description: String {
        switch self {
        case .automatic: "automatic"
        case .ipv4(let address): address
        case .mac(let mac): mac.description
        }
    }
}

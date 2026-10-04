/// A 48-bit Ethernet / Wi-Fi hardware address.
public struct MACAddress: Sendable, Hashable, CustomStringConvertible, Codable {
    /// Always exactly six bytes.
    public let bytes: [UInt8]

    /// Parses the formats people and tools actually produce, case-insensitively, ignoring surrounding
    /// whitespace:
    /// - `a4:5e:60:01:02:03`, and macOS `arp` style without leading zeros, `a4:5e:60:1:2:3`
    /// - `A4-5E-60-01-02-03` (Windows)
    /// - `a45e.6001.0203` (Cisco)
    /// - `a45e60010203` (bare hex)
    ///
    /// Returns `nil` for anything else, including mixed separators and wrong group counts.
    public init?(_ string: String) {
        let text = Array(string.trimmingWhitespace().utf8)
        // The separator picks the format: how many groups there are and how many hex digits each may have.
        let format: (separator: UInt8?, groups: Int, digits: ClosedRange<Int>) =
            if text.contains(UInt8(ascii: ":")) {
                (UInt8(ascii: ":"), 6, 1...2)
            } else if text.contains(UInt8(ascii: "-")) {
                (UInt8(ascii: "-"), 6, 2...2)
            } else if text.contains(UInt8(ascii: ".")) {
                (UInt8(ascii: "."), 3, 4...4)
            } else {
                (nil, 1, 12...12)
            }
        let groups = format.separator.map { text.split(separator: $0, omittingEmptySubsequences: false) }
            ?? [text[...]]
        guard groups.count == format.groups else { return nil }
        var nibbles: [UInt8] = []
        for group in groups {
            let values = group.compactMap(Self.hexDigitValue)
            guard format.digits.contains(group.count), values.count == group.count else { return nil }
            // Left-pad unpadded groups such as macOS's `6` to the width the group stands for.
            nibbles += Array(repeating: 0, count: 12 / format.groups - values.count) + values
        }
        bytes = stride(from: 0, to: 12, by: 2).map { nibbles[$0] << 4 | nibbles[$0 + 1] }
    }

    /// Creates an address from exactly six bytes, or returns `nil`.
    public init?(bytes: some Sequence<UInt8>) {
        let bytes = Array(bytes)
        guard bytes.count == 6 else { return nil }
        self.bytes = bytes
    }

    /// Canonical lowercase, colon-separated, zero-padded form: `a4:5e:60:01:02:03`.
    public var description: String {
        bytes.map { ($0 < 0x10 ? "0" : "") + String($0, radix: 16) }.joined(separator: ":")
    }

    /// Encodes as the canonical string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    /// Decodes from any string format accepted by `init?(_:)`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let address = MACAddress(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a MAC address: \(string)")
        }
        self = address
    }

    private static func hexDigitValue(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): character - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): character - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): character - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

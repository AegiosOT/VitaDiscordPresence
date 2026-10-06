/// The fixed-layout record the VitaPresence plugin sends on every connection.
///
/// Wire format (little-endian, no framing, the client sends nothing):
///
/// | offset | size | field                                                       |
/// |-------:|-----:|-------------------------------------------------------------|
/// | 0      | 4    | magic `0xCAFECAFE` (bytes `FE CA FE CA`)                    |
/// | 4      | 4    | index (int32): 0 = LiveArea, 1...20 = app slot + 1          |
/// | 8      | 10   | title ID, NUL-terminated inside the field                   |
/// | 18     | 128  | title (UTF-8), NUL-terminated except in one SFO path        |
/// | 146    | 37   | content ID (plugin 1.1 and later), NUL-terminated, or empty |
/// | 183    | 1    | ARM EABI tail padding, always zero                          |
///
/// Plugin 1.1 sends 184 bytes and then closes the connection. Earlier plugins end after the title with two
/// bytes of zero tail padding (148 bytes), so their packets carry no content ID. Bytes after the first NUL in
/// a string field are stale data from earlier packets and must be ignored.
public enum VitaPacket {
    /// TCP port the plugin listens on (0xCAFE).
    public static let port: UInt16 = 0xCAFE
    /// Value of the first four bytes of every packet.
    public static let magic: UInt32 = 0xCAFE_CAFE
    /// Bytes covered by the fields every plugin sends. Anything shorter is invalid.
    public static let minimumLength = 146
    /// What plugins before 1.1 send: `sizeof(vitapresence_data_t)` including two bytes of tail padding.
    public static let wireLength = 148
    /// What plugin 1.1 sends: the content ID field and one byte of tail padding follow the title.
    public static let wireLengthWithContentID = 184
    /// Upper bound a client reads before giving up (guards against some other service on the port).
    public static let maximumReadLength = 4096
    /// Largest valid `index` (the plugin scans 20 app slots).
    public static let maximumIndex: Int32 = 20

    private static let titleIDField = 8..<18
    private static let titleField = 18..<146
    private static let contentIDField = 146..<183
    /// The only content ID shape accepted: `-` and `_` stand for themselves, every letter stands for an
    /// uppercase ASCII letter or a digit.
    private static let contentIDShape = Array("XXYYYY-TTTTNNNNN_NN-LLLLLLLLLLLLLLLL".utf8)

    /// Parses a packet. Accepts any length of at least 146 bytes and ignores trailing bytes.
    ///
    /// String fields are cut at the first NUL (or the end of the field). An incomplete trailing UTF-8
    /// sequence is dropped, other invalid UTF-8 becomes U+FFFD, C0 control characters and DEL are removed,
    /// and surrounding whitespace is trimmed. For LiveArea packets (index 0) both strings are returned empty
    /// and the content ID `nil`, whatever the fields contain.
    ///
    /// The content ID is read only when at least 183 bytes arrived. It is cut at the first NUL and kept only
    /// when it has exactly the shape `XXYYYY-TTTTNNNNN_NN-LLLLLLLLLLLLLLLL`: 36 characters, `-` at offsets 6
    /// and 19, `_` at 16, and ASCII letters or digits everywhere else. Letters may be either case; the value
    /// is returned in uppercase. Anything else gives `nil`.
    public static func parse(_ bytes: some Collection<UInt8>) throws(VitaPacketError) -> VitaTitle {
        let packet = Array(bytes.prefix(contentIDField.upperBound))
        guard packet.count >= minimumLength else { throw .tooShort(byteCount: packet.count) }
        let receivedMagic = littleEndianUInt32(in: packet, at: 0)
        guard receivedMagic == magic else { throw .badMagic(receivedMagic) }
        let index = Int32(bitPattern: littleEndianUInt32(in: packet, at: 4))
        guard (0...maximumIndex).contains(index) else { throw .invalidIndex(index) }
        guard index != 0 else { return .liveArea }
        return VitaTitle(
            index: index,
            titleID: text(in: packet[titleIDField]),
            name: text(in: packet[titleField]),
            contentID: packet.count == contentIDField.upperBound ? contentID(in: packet[contentIDField]) : nil
        )
    }

    /// Encodes `title` exactly as the plugin would, with zero padding: 148 bytes like plugins before 1.1, or
    /// 184 bytes like plugin 1.1 when `title.contentID` isn't `nil`. Used by tests and mock servers. Strings
    /// longer than their field are cut to 9 bytes (title ID), 127 bytes (title) or 36 bytes (content ID)
    /// without splitting a UTF-8 sequence, and are NUL-terminated.
    public static func encode(_ title: VitaTitle, magic: UInt32 = VitaPacket.magic) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: title.contentID == nil ? wireLength : wireLengthWithContentID)
        packet.replaceSubrange(0..<4, with: littleEndianBytes(magic))
        packet.replaceSubrange(4..<8, with: littleEndianBytes(UInt32(bitPattern: title.index)))
        write(title.titleID, into: &packet, field: titleIDField)
        write(title.name, into: &packet, field: titleField)
        if let contentID = title.contentID {
            write(contentID, into: &packet, field: contentIDField)
        }
        return packet
    }

    private static func littleEndianUInt32(in bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private static func littleEndianBytes(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    /// Decodes a string field as described on `parse`.
    private static func text(in field: ArraySlice<UInt8>) -> String {
        var bytes = field.prefix(while: { $0 != 0 })
        bytes.removeLast(incompleteSequenceLength(atEndOf: bytes))
        let scalars = String(decoding: bytes, as: UTF8.self).unicodeScalars
        var printable = ""
        printable.unicodeScalars.append(contentsOf: scalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
        return String(printable.trimmingWhitespace())
    }

    /// The content ID in `field` up to the first NUL, or `nil` unless it has exactly `contentIDShape`.
    private static func contentID(in field: ArraySlice<UInt8>) -> String? {
        let id = field.prefix(while: { $0 != 0 })
        guard id.count == contentIDShape.count,
              zip(id, contentIDShape).allSatisfy({ byte, shape in
                  isUppercaseLetterOrDigit(shape) ? isLetterOrDigit(byte) : byte == shape
              })
        else { return nil }
        return String(decoding: id, as: UTF8.self).uppercased()
    }

    private static func isUppercaseLetterOrDigit(_ byte: UInt8) -> Bool {
        isLetterOrDigit(byte) && !((UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte))
    }

    private static func isLetterOrDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    /// The number of bytes at the end of `bytes` that start a well-formed UTF-8 sequence but stop before its
    /// end, as left by the plugin cutting a title at 127 or 128 bytes. Invalid bytes don't count: they are
    /// left in place to decode as U+FFFD.
    private static func incompleteSequenceLength(atEndOf bytes: ArraySlice<UInt8>) -> Int {
        // A sequence is at most four bytes: step back over up to three continuation bytes to its lead byte.
        var start = bytes.endIndex
        while start > bytes.startIndex, bytes.endIndex - start < 3, bytes[start - 1] & 0xC0 == 0x80 {
            start -= 1
        }
        guard start > bytes.startIndex else { return 0 }
        let lead = bytes[start - 1]
        // Sequence length and the valid range of the byte after the lead (Unicode Table 3-7).
        let length: Int
        let second: ClosedRange<UInt8>
        switch lead {
        case 0xC2...0xDF: (length, second) = (2, 0x80...0xBF)
        case 0xE0: (length, second) = (3, 0xA0...0xBF)
        case 0xE1...0xEC, 0xEE...0xEF: (length, second) = (3, 0x80...0xBF)
        case 0xED: (length, second) = (3, 0x80...0x9F)
        case 0xF0: (length, second) = (4, 0x90...0xBF)
        case 0xF1...0xF3: (length, second) = (4, 0x80...0xBF)
        case 0xF4: (length, second) = (4, 0x80...0x8F)
        default: return 0
        }
        let present = bytes.endIndex - (start - 1)
        guard present < length, present == 1 || second.contains(bytes[start]) else { return 0 }
        return present
    }

    /// Writes `string` NUL-terminated into `field`, cut to fit without splitting a UTF-8 sequence.
    private static func write(_ string: String, into packet: inout [UInt8], field: Range<Int>) {
        let utf8 = Array(string.utf8)
        var length = min(utf8.count, field.count - 1)
        while length < utf8.count, utf8[length] & 0xC0 == 0x80 {
            length -= 1
        }
        packet.replaceSubrange(field.lowerBound..<(field.lowerBound + length), with: utf8[..<length])
    }
}

public enum VitaPacketError: Error, Equatable, Sendable {
    /// Fewer than `VitaPacket.minimumLength` bytes.
    case tooShort(byteCount: Int)
    /// The first four bytes are not `0xCAFECAFE` (little-endian).
    case badMagic(UInt32)
    /// The index is outside `0...VitaPacket.maximumIndex`.
    case invalidIndex(Int32)
}

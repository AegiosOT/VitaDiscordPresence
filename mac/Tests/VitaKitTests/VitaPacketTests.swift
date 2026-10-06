import Foundation
import Testing
@testable import VitaKit

/// Builds a packet field by field, for contents `VitaPacket.encode` never produces (stale tails, missing NULs,
/// invalid UTF-8, malformed content IDs). Unwritten bytes are zero.
private func rawPacket(
    index: Int32,
    titleIDField: [UInt8] = [],
    titleField: [UInt8] = [],
    contentIDField: [UInt8] = [],
    magic: UInt32 = VitaPacket.magic,
    length: Int = VitaPacket.wireLength
) -> [UInt8] {
    precondition(titleIDField.count <= 10 && titleField.count <= 128 && contentIDField.count <= 37)
    precondition(length >= max(VitaPacket.minimumLength, 146 + contentIDField.count))
    var bytes = [UInt8](repeating: 0, count: length)
    withUnsafeBytes(of: magic.littleEndian) { bytes.replaceSubrange(0..<4, with: $0) }
    withUnsafeBytes(of: index.littleEndian) { bytes.replaceSubrange(4..<8, with: $0) }
    bytes.replaceSubrange(8..<(8 + titleIDField.count), with: titleIDField)
    bytes.replaceSubrange(18..<(18 + titleField.count), with: titleField)
    bytes.replaceSubrange(146..<(146 + contentIDField.count), with: contentIDField)
    return bytes
}

/// The name parsed from an app packet whose title field holds `field`.
private func parsedName(_ field: [UInt8]) throws -> String {
    try VitaPacket.parse(rawPacket(index: 1, titleIDField: Array("PCSE00120".utf8), titleField: field)).name
}

struct VitaPacketParsingTests {
    let persona = VitaTitle(index: 3, titleID: "PCSE00120", name: "Persona 4 Golden")

    @Test(arguments: [146, 148, 4096])
    func acceptsAnyLengthFromTheMinimum(length: Int) throws {
        let bytes = VitaPacket.encode(persona) + [UInt8](repeating: 0xAB, count: 4096)
        #expect(try VitaPacket.parse(bytes.prefix(length)) == persona)
    }

    @Test func acceptsSlicesAndData() throws {
        let shifted = [0xFF, 0xFF] + VitaPacket.encode(persona)
        #expect(try VitaPacket.parse(shifted.dropFirst(2)) == persona)
        #expect(try VitaPacket.parse(Data(VitaPacket.encode(persona))) == persona)
    }

    @Test(arguments: [0, 1, 8, 145])
    func rejectsShortPackets(length: Int) {
        #expect(throws: VitaPacketError.tooShort(byteCount: length)) {
            try VitaPacket.parse(VitaPacket.encode(persona).prefix(length))
        }
    }

    @Test func rejectsBadMagic() {
        #expect(throws: VitaPacketError.badMagic(0)) {
            try VitaPacket.parse([UInt8](repeating: 0, count: VitaPacket.wireLength))
        }
        #expect(throws: VitaPacketError.badMagic(0x1234_5678)) {
            try VitaPacket.parse(VitaPacket.encode(persona, magic: 0x1234_5678))
        }
    }

    @Test func rejectsMagicWrittenBigEndian() {
        // A big-endian writer sends CA FE CA FE, which reads as 0xFECAFECA.
        var bytes = VitaPacket.encode(persona)
        bytes.replaceSubrange(0..<4, with: [0xCA, 0xFE, 0xCA, 0xFE])
        #expect(throws: VitaPacketError.badMagic(0xFECA_FECA)) { try VitaPacket.parse(bytes) }
    }

    @Test(arguments: [-1, 21, Int32.max, Int32.min])
    func rejectsIndexOutOfRange(index: Int32) {
        #expect(throws: VitaPacketError.invalidIndex(index)) {
            try VitaPacket.parse(VitaPacket.encode(VitaTitle(index: index, titleID: "PCSE00120", name: "Persona")))
        }
    }

    @Test(arguments: [1, 20])
    func acceptsIndexBounds(index: Int32) throws {
        let title = VitaTitle(index: index, titleID: "PCSE00120", name: "Persona")
        #expect(try VitaPacket.parse(VitaPacket.encode(title)) == title)
    }

    @Test func liveAreaIgnoresStaleFieldTails() throws {
        // In the LiveArea the plugin only clears the first byte of each field.
        let bytes = rawPacket(
            index: 0,
            titleIDField: [0] + Array("CSE00120".utf8),
            titleField: [0] + Array("ersona 4 Golden".utf8)
        )
        let title = try VitaPacket.parse(bytes)
        #expect(title == .liveArea)
        #expect(title.isLiveArea)
    }

    @Test func liveAreaReturnsEmptyStringsWhateverTheFieldsHold() throws {
        let bytes = VitaPacket.encode(VitaTitle(index: 0, titleID: "PCSE00120", name: "Persona 4 Golden"))
        #expect(try VitaPacket.parse(bytes) == .liveArea)
    }

    @Test func ignoresStaleBytesAfterTheFirstNUL() throws {
        let bytes = rawPacket(
            index: 2,
            titleIDField: Array("XMB\0E00120".utf8),
            titleField: Array("Adrenaline XMB Menu\0olden stale tail".utf8)
        )
        #expect(try VitaPacket.parse(bytes) == VitaTitle(index: 2, titleID: "XMB", name: "Adrenaline XMB Menu"))
    }

    @Test func readsAnUnterminatedTitleUpToTheFieldEnd() throws {
        let name = String(repeating: "A", count: 127) + "Z"
        #expect(try parsedName(Array(name.utf8)) == name)
    }

    @Test func unterminatedTitleDoesNotRunIntoTrailingBytes() throws {
        var bytes = rawPacket(index: 1, titleField: Array(repeating: UInt8(ascii: "A"), count: 128), length: 200)
        bytes.replaceSubrange(146..<200, with: repeatElement(UInt8(ascii: "B"), count: 54))
        #expect(try VitaPacket.parse(bytes).name == String(repeating: "A", count: 128))
    }

    @Test func dropsACharacterSplitByThePluginsCut() throws {
        // The plugin cuts titles at 127 bytes, which can split a multibyte character.
        let full = String(repeating: "テスト", count: 15)
        #expect(try parsedName(Array(full.utf8.prefix(127))) == String(full.prefix(42)))
        #expect(try parsedName(Array(full.utf8.prefix(128))) == String(full.prefix(42)))
    }

    @Test(arguments: [[0xC3], [0xE3], [0xE3, 0x83], [0xF0], [0xF0, 0x9F], [0xF0, 0x9F, 0x98], [0xF4, 0x8F, 0xBF]])
    func dropsAnIncompleteTrailingSequence(tail: [UInt8]) throws {
        #expect(try parsedName(Array("Gravity Rush".utf8) + tail) == "Gravity Rush")
    }

    @Test(arguments: [
        ([0x41, 0xFF, 0x42], "A\u{FFFD}B"),
        ([0x41, 0xE3, 0x42], "A\u{FFFD}B"),  // truncated sequence in the middle
        ([0x41, 0x80], "A\u{FFFD}"),  // a stray continuation byte isn't a cut-off character
        ([0x41, 0xC0], "A\u{FFFD}"),  // never a valid lead byte
        ([0x41, 0xE0, 0x80], "A\u{FFFD}\u{FFFD}"),  // overlong prefix
        ([0x41, 0xED, 0xA0], "A\u{FFFD}\u{FFFD}"),  // surrogate prefix
        ([0x41, 0xF4, 0x90], "A\u{FFFD}\u{FFFD}"),  // beyond U+10FFFF
    ])
    func replacesInvalidUTF8(field: [UInt8], expected: String) throws {
        #expect(try parsedName(field) == expected)
    }

    @Test func stripsControlCharactersAndTrimsWhitespace() throws {
        #expect(try parsedName(Array("  Per\tso\u{1}na\u{7F} 4\r\n Golden\u{1B}  ".utf8)) == "Persona 4 Golden")
        #expect(try parsedName(Array("\u{A0}Gravity Rush™ 重力\u{3000}".utf8)) == "Gravity Rush™ 重力")
    }

    @Test func cleansTheTitleIDToo() throws {
        let bytes = rawPacket(index: 4, titleIDField: Array(" PCSE\u{7}001 ".utf8), titleField: Array("Name".utf8))
        #expect(try VitaPacket.parse(bytes).titleID == "PCSE001")
    }
}

/// Content IDs, which plugin 1.1 sends in 37 more bytes after the title.
struct VitaPacketContentIDTests {
    let persona = VitaTitle(index: 3, titleID: "PCSE00120", name: "Persona 4 Golden")
    let personaContentID = "UP0005-PCSE00120_00-PERSONA4GOLDEN01"

    /// An app packet of `length` bytes whose content ID field holds `field`. Bytes after the field are 0xAB, as
    /// from a future plugin that sends more.
    private func packet(contentIDField field: [UInt8], length: Int = VitaPacket.wireLengthWithContentID) -> [UInt8] {
        var bytes = rawPacket(
            index: persona.index,
            titleIDField: Array(persona.titleID.utf8),
            titleField: Array(persona.name.utf8),
            contentIDField: field,
            length: max(length, 183)
        )
        bytes.replaceSubrange(183..., with: repeatElement(0xAB, count: bytes.count - 183))
        return Array(bytes.prefix(length))
    }

    private func parsedContentID(_ field: String) throws -> String? {
        try VitaPacket.parse(packet(contentIDField: Array(field.utf8))).contentID
    }

    @Test(arguments: [183, 184, 204, 4096])
    func readsTheContentIDOnceItsFieldArrived(length: Int) throws {
        // 183 bytes end with the field, 184 is plugin 1.1, and 204 the prototype with an extension block.
        let title = try VitaPacket.parse(packet(contentIDField: Array(personaContentID.utf8), length: length))
        #expect(title.contentID == personaContentID)
        #expect(title.titleID == persona.titleID)
        #expect(title.name == persona.name)
    }

    @Test(arguments: [146, 148, 160, 182])
    func packetsThatEndBeforeTheFieldDoesHaveNoContentID(length: Int) throws {
        // 146 and 148 bytes are what older plugins send; 182 bytes stop right before the field's NUL.
        let title = try VitaPacket.parse(packet(contentIDField: Array(personaContentID.utf8), length: length))
        #expect(title == persona)
        #expect(title.contentID == nil)
    }

    @Test(arguments: [
        "UP0005-PCSE00120_00-PERSONA4GOLDEN01",
        "EP9000-PCSF00011_00-GRAVITYRUSHEU001",
        "JP0700-PCSG00563_00-0000000000000000",
        "HP0700-PCSH00021_00-ABCDEFGHIJKLMNOP",
        "UP4433-PCSE00434_00-0000000000000001",
    ])
    func acceptsWellFormedContentIDs(contentID: String) throws {
        #expect(try parsedContentID(contentID) == contentID)
    }

    @Test(arguments: [
        "",  // system apps, and games whose param.sfo has none
        "UP0005-PCSE00120_00-PERSONA4GOLDEN0",  // 35 characters
        "UP0005-PCSE00120_00-PERSONA4GOLDEN012",  // 37 characters fill the field, leaving no NUL
        "UP0005",
        "UP0005_PCSE00120_00-PERSONA4GOLDEN01",  // '_' at 6
        "UP0005-PCSE00120-00-PERSONA4GOLDEN01",  // '-' at 16
        "UP0005-PCSE00120_00_PERSONA4GOLDEN01",  // '_' at 19
        "UP0005-PCSE00120_00-PERSONA4-GOLDEN1",  // a separator where letters go
        "UP0005 PCSE00120_00-PERSONA4GOLDEN01",
        " UP0005-PCSE00120_00-PERSONA4GOLDEN0",
        "UP0005-PCSE00120_00-PERSONA4GOLDÉN1",  // 36 bytes, one letter not ASCII
        "ＵP0005-PCSE00120_00-PERSONA4GOLDEN",  // 36 bytes, a fullwidth letter
        "UP0005-PCSE00120_00-PERSONA4GOLDEN\u{1}1",
    ])
    func rejectsAnythingElse(contentID: String) throws {
        #expect(try parsedContentID(contentID) == nil)
    }

    @Test func ignoresBytesAfterTheFirstNUL() throws {
        // Whatever follows a NUL is stale: a cut ID isn't put back together, and an empty field stays empty.
        #expect(try parsedContentID("UP0005-PCSE00120_00-PERS\0NA4GOLDEN01") == nil)
        #expect(try parsedContentID("\0P0005-PCSE00120_00-PERSONA4GOLDEN01") == nil)
        #expect(try parsedContentID(personaContentID + "\0") == personaContentID)
    }

    @Test func liveAreaHasNoContentID() throws {
        let bytes = rawPacket(index: 0, contentIDField: Array(personaContentID.utf8), length: 184)
        let title = try VitaPacket.parse(bytes)
        #expect(title == .liveArea)
        #expect(title.contentID == nil)
    }
}

struct VitaPacketEncodingTests {
    @Test func usesThePluginLayout() {
        let bytes = VitaPacket.encode(VitaTitle(index: 7, titleID: "PCSB00245", name: "Gravity Rush"))
        #expect(bytes.count == VitaPacket.wireLength)
        #expect(Array(bytes[0..<4]) == [0xFE, 0xCA, 0xFE, 0xCA])
        #expect(Array(bytes[4..<8]) == [7, 0, 0, 0])
        #expect(Array(bytes[8..<18]) == Array("PCSB00245".utf8) + [0])
        #expect(Array(bytes[18..<30]) == Array("Gravity Rush".utf8))
        #expect(bytes[30...].allSatisfy { $0 == 0 })
    }

    @Test func writesTheIndexAsLittleEndianTwosComplement() {
        let bytes = VitaPacket.encode(VitaTitle(index: -2, titleID: "", name: ""))
        #expect(Array(bytes[4..<8]) == [0xFE, 0xFF, 0xFF, 0xFF])
    }

    @Test(arguments: [
        VitaTitle(index: 1, titleID: "PCSE00120", name: "Persona 4 Golden"),
        VitaTitle(index: 20, titleID: "XMB", name: "Adrenaline XMB Menu"),
        VitaTitle(index: 5, titleID: "NPXS10015", name: "設定"),
        VitaTitle(index: 9, titleID: "PCSB00245", name: "GRAVITY DAZE™ 重力的眩暈 🎮"),
        VitaTitle(index: 2, titleID: "", name: ""),
        .liveArea,
    ])
    func roundTrips(title: VitaTitle) throws {
        #expect(try VitaPacket.parse(VitaPacket.encode(title)) == title)
    }

    @Test func cutsLongStringsToTheirFieldsAndKeepsTheNUL() throws {
        let long = VitaTitle(index: 4, titleID: "PCSE001209999", name: String(repeating: "x", count: 300))
        let bytes = VitaPacket.encode(long)
        #expect(bytes.count == VitaPacket.wireLength)
        #expect(bytes[17] == 0)
        #expect(bytes[145] == 0)
        let parsed = try VitaPacket.parse(bytes)
        #expect(parsed.titleID == "PCSE00120")
        #expect(parsed.name == String(repeating: "x", count: 127))
    }

    @Test(arguments: [
        (String(repeating: "テ", count: 50), 126),  // 3-byte characters: 42 fit
        ("a" + String(repeating: "テ", count: 50), 127),  // ends exactly at the limit
        ("ab" + String(repeating: "テ", count: 50), 125),
        (String(repeating: "é", count: 70), 126),
        (String(repeating: "🎮", count: 40), 124),
    ])
    func cutsMultibyteNamesWithoutSplittingCharacters(name: String, byteCount: Int) throws {
        let bytes = VitaPacket.encode(VitaTitle(index: 1, titleID: "PCSE00120", name: name))
        #expect(bytes[18 + byteCount] == 0)
        #expect(bytes[18 + byteCount - 1] != 0)
        let parsed = try VitaPacket.parse(bytes)
        #expect(parsed.name.utf8.count == byteCount)
        #expect(name.hasPrefix(parsed.name))
    }

    @Test func cutsMultibyteTitleIDsWithoutSplittingCharacters() throws {
        func roundTripped(_ titleID: String) throws -> String {
            try VitaPacket.parse(VitaPacket.encode(VitaTitle(index: 1, titleID: titleID, name: "x"))).titleID
        }
        #expect(try roundTripped("テスト") == "テスト")  // exactly 9 bytes
        #expect(try roundTripped("aテスト") == "aテス")  // 10 bytes: the last character doesn't fit
    }

    @Test func writesAContentIDLikePlugin11() {
        let contentID = "UP0005-PCSE00120_00-PERSONA4GOLDEN01"
        let withoutContentID = VitaTitle(index: 3, titleID: "PCSE00120", name: "Persona 4 Golden")
        var title = withoutContentID
        title.contentID = contentID
        let bytes = VitaPacket.encode(title)
        #expect(bytes.count == VitaPacket.wireLengthWithContentID)
        #expect(bytes[..<146] == VitaPacket.encode(withoutContentID)[..<146])
        #expect(Array(bytes[146..<182]) == Array(contentID.utf8))
        #expect(bytes[182] == 0)
        #expect(bytes[183] == 0)
    }

    @Test func cutsALongContentIDAndKeepsTheNUL() throws {
        let contentID = "UP0005-PCSE00120_00-PERSONA4GOLDEN01"
        let long = VitaTitle(index: 1, titleID: "PCSE00120", name: "x", contentID: contentID + "XYZ")
        let bytes = VitaPacket.encode(long)
        #expect(bytes.count == VitaPacket.wireLengthWithContentID)
        #expect(bytes[182] == 0)
        #expect(try VitaPacket.parse(bytes).contentID == contentID)
    }

    @Test func writesAnyContentIDButOnlyParsesWellFormedOnes() throws {
        for contentID in ["", "not a content ID"] {
            let bytes = VitaPacket.encode(VitaTitle(index: 1, titleID: "PCSE00120", name: "x", contentID: contentID))
            #expect(bytes.count == VitaPacket.wireLengthWithContentID)
            #expect(Array(bytes[146..<(146 + contentID.utf8.count)]) == Array(contentID.utf8))
            #expect(try VitaPacket.parse(bytes).contentID == nil)
        }
    }

    @Test func acceptsLowercaseContentIDsAsUppercase() throws {
        for contentID in ["up0005-pcse00120_00-persona4golden01", "Up0005-Pcse00120_00-Persona4Golden01"] {
            let bytes = VitaPacket.encode(VitaTitle(index: 1, titleID: "PCSE00120", name: "x", contentID: contentID))
            #expect(try VitaPacket.parse(bytes).contentID == "UP0005-PCSE00120_00-PERSONA4GOLDEN01")
        }
    }

    @Test(arguments: [
        VitaTitle(index: 1, titleID: "PCSE00120", name: "Persona 4", contentID: "UP0005-PCSE00120_00-PERSONA4GOLDEN01"),
        VitaTitle(index: 20, titleID: "PCSF00011", name: "Gravity", contentID: "EP9000-PCSF00011_00-GRAVITYRUSHEU001"),
        VitaTitle(index: 9, titleID: "PCSG00563", name: "重力的眩暈 🎮", contentID: "JP0700-PCSG00563_00-0000000000000000"),
        VitaTitle(index: 5, titleID: "NPXS10015", name: "設定"),
    ])
    func roundTripsContentIDs(title: VitaTitle) throws {
        #expect(try VitaPacket.parse(VitaPacket.encode(title)) == title)
    }

    @Test func aLiveAreaPacketDropsTheContentID() throws {
        let title = VitaTitle(index: 0, titleID: "", name: "", contentID: "UP0005-PCSE00120_00-PERSONA4GOLDEN01")
        let bytes = VitaPacket.encode(title)
        #expect(bytes.count == VitaPacket.wireLengthWithContentID)
        #expect(try VitaPacket.parse(bytes) == .liveArea)
    }
}

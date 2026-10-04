import Foundation
import Testing
@testable import DiscordIPC

@Suite struct DiscordTextTests {
    @Test(arguments: [nil, "", " ", "\n\t  \r\n", "\u{3000}"] as [String?])
    func blankTextBecomesNil(text: String?) {
        #expect(DiscordText.clamp(text) == nil)
    }

    @Test func trimsOnlyTheEnds() {
        #expect(DiscordText.clamp("  Persona 4  Golden \n") == "Persona 4  Golden")
    }

    @Test(arguments: ["a", "\u{6F22}", "7", " x "])
    func padsOneUnitTextWithAZeroWidthSpace(text: String) throws {
        let clamped = try #require(DiscordText.clamp(text))
        #expect(clamped == text.trimmingCharacters(in: .whitespaces) + "\u{200B}")
        #expect(clamped.utf16.count == 2)
    }

    @Test(arguments: ["ab", "\u{1F63A}"])
    func keepsTwoUnitText(text: String) {
        // A single emoji is one character but two UTF-16 units, which is enough.
        #expect(DiscordText.clamp(text) == text)
    }

    @Test func keepsExactly128Units() {
        let text = String(repeating: "a", count: 128)
        #expect(DiscordText.clamp(text) == text)
        #expect(DiscordText.clamp("  " + text + "\n") == text)
    }

    @Test func cuts129UnitsToFitWithAnEllipsis() throws {
        let clamped = try #require(DiscordText.clamp(String(repeating: "a", count: 129)))
        #expect(clamped == String(repeating: "a", count: 127) + "\u{2026}")
        #expect(clamped.utf16.count == 128)
    }

    @Test func neverSplitsSurrogatePairs() throws {
        let cat = "\u{1F63A}"
        #expect(DiscordText.clamp(String(repeating: cat, count: 64)) == String(repeating: cat, count: 64))
        // 65 cats are 130 units; a 64th cat would leave no room for the ellipsis.
        let clamped = try #require(DiscordText.clamp(String(repeating: cat, count: 65)))
        #expect(clamped == String(repeating: cat, count: 63) + "\u{2026}")
        #expect(clamped.utf16.count == 127)
    }

    @Test func neverSplitsCombiningSequences() throws {
        let accented = "e\u{301}" // One character, two UTF-16 units.
        let clamped = try #require(DiscordText.clamp(String(repeating: accented, count: 70)))
        #expect(clamped == String(repeating: accented, count: 63) + "\u{2026}")
        #expect(clamped.utf16.count == 127)
    }

    @Test func neverSplitsEmojiSequences() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}" // 11 units, one character.
        let text = String(repeating: "a", count: 120) + family
        #expect(DiscordText.clamp(text) == String(repeating: "a", count: 120) + "\u{2026}")

        let flag = "\u{1F1EF}\u{1F1F5}" // 4 units, one character.
        let flags = DiscordText.clamp(String(repeating: flag, count: 33))
        #expect(flags == String(repeating: flag, count: 31) + "\u{2026}")
    }

    @Test func countsCJKAsOneUnitEach() {
        let kanji = "\u{6F22}"
        #expect(DiscordText.clamp(String(repeating: kanji, count: 128)) == String(repeating: kanji, count: 128))
        let cut = DiscordText.clamp(String(repeating: kanji, count: 129))
        #expect(cut == String(repeating: kanji, count: 127) + "\u{2026}")
    }

    @Test func honoursCustomLimits() {
        #expect(DiscordText.clamp("abcdef", maxUnits: 4) == "abc\u{2026}")
        #expect(DiscordText.clamp("a", minUnits: 3) == "a\u{200B}\u{200B}")
    }

    @Test func prefixStopsAtTheLastWholeCharacter() {
        #expect(DiscordText.prefix("ab\u{1F63A}c", maxUnits: 3) == "ab")
        #expect(DiscordText.prefix("ab\u{1F63A}c", maxUnits: 4) == "ab\u{1F63A}")
        #expect(DiscordText.prefix("abc", maxUnits: 0) == "")
    }
}

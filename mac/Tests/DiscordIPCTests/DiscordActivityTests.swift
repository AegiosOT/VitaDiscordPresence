import Foundation
import Testing
@testable import DiscordIPC

@Suite struct DiscordActivityTests {
    @Test func encodesDiscordsSnakeCaseKeys() throws {
        let activity = DiscordActivity(
            details: "Persona 4 Golden",
            state: "Chilling",
            timestamps: .init(start: 1_727_000_000_123),
            assets: .init(largeImage: "vita", largeText: "PS Vita")
        )
        #expect(try json(activity) == """
            {"assets":{"large_image":"vita","large_text":"PS Vita"},"details":"Persona 4 Golden",\
            "state":"Chilling","timestamps":{"start":1727000000123}}
            """)
    }

    @Test func omitsNilFields() throws {
        #expect(try json(DiscordActivity()) == "{}")
        #expect(try json(DiscordActivity(details: "Gravity Rush")) == #"{"details":"Gravity Rush"}"#)
        #expect(try json(DiscordActivity(assets: .init(largeImage: "vita"))) == #"{"assets":{"large_image":"vita"}}"#)
        #expect(try json(DiscordActivity.Timestamps(start: nil)) == "{}")
    }

    @Test func timestampsAreWholeMilliseconds() throws {
        let start = Int64(Date(timeIntervalSince1970: 1_727_000_000.25).timeIntervalSince1970 * 1000)
        #expect(try json(DiscordActivity.Timestamps(start: start)) == #"{"start":1727000000250}"#)
    }

    @Test func decodesDiscordsKeys() throws {
        let payload = Data("""
            {"details":"x","assets":{"large_image":"k","large_text":"t"},"timestamps":{"start":5}}
            """.utf8)
        let decoded = try JSONDecoder().decode(DiscordActivity.self, from: payload)
        #expect(decoded == DiscordActivity(
            details: "x",
            timestamps: .init(start: 5),
            assets: .init(largeImage: "k", largeText: "t")
        ))
    }

    @Test func sanitizedClampsText() {
        let activity = DiscordActivity(
            details: "  " + String(repeating: "a", count: 200),
            state: "x",
            assets: .init(largeImage: "vita", largeText: "A")
        )
        let sanitized = activity.sanitized()
        #expect(sanitized.details == String(repeating: "a", count: 127) + "\u{2026}")
        #expect(sanitized.state == "x\u{200B}")
        #expect(sanitized.assets == .init(largeImage: "vita", largeText: "A\u{200B}"))
    }

    @Test func sanitizedDropsBlankText() {
        let sanitized = DiscordActivity(details: " \n", state: "", assets: .init(largeImage: "vita", largeText: " "))
            .sanitized()
        #expect(sanitized == DiscordActivity(assets: .init(largeImage: "vita", largeText: nil)))
    }

    @Test(arguments: [nil, "", "   \n"] as [String?])
    func sanitizedDropsAssetsWithoutAnImage(image: String?) {
        let sanitized = DiscordActivity(details: "Game", assets: .init(largeImage: image, largeText: "Hover text"))
            .sanitized()
        #expect(sanitized == DiscordActivity(details: "Game"))
    }

    @Test func sanitizedTrimsTheImage() {
        #expect(DiscordActivity(assets: .init(largeImage: "  vita\n")).sanitized().assets?.largeImage == "vita")
    }

    @Test func sanitizedKeepsHTTPSImageURLsDiscordCanSign() {
        let fits = "https://example.com/" + String(repeating: "x", count: 236) // 256 characters
        #expect(DiscordActivity(assets: .init(largeImage: fits)).sanitized().assets?.largeImage == fits)
    }

    @Test(arguments: [
        "https://example.com/" + String(repeating: "x", count: 237), // 257 characters
        "http://example.com/vita.png",
        "https://example.com/a b.png",
    ])
    func sanitizedDropsImageURLsDiscordCantSign(url: String) {
        #expect(DiscordActivity(assets: .init(largeImage: url, largeText: "Vita")).sanitized().assets == nil)
    }

    @Test func sanitizedCutsAssetKeysTo300Units() throws {
        let key = String(repeating: "x", count: 400)
        let image = DiscordActivity(assets: .init(largeImage: key)).sanitized().assets?.largeImage
        #expect(image == String(key.prefix(300)))

        let emoji = String(repeating: "\u{1F63A}", count: 200) // 400 UTF-16 units.
        let cut = try #require(DiscordActivity(assets: .init(largeImage: emoji)).sanitized().assets?.largeImage)
        #expect(cut == String(repeating: "\u{1F63A}", count: 150))
    }

    @Test(arguments: [nil, 0, -1, .min] as [Int64?])
    func sanitizedDropsTimestampsWithoutAPositiveStart(start: Int64?) {
        #expect(DiscordActivity(details: "Game", timestamps: .init(start: start)).sanitized().timestamps == nil)
    }

    @Test func sanitizedKeepsAPositiveStart() {
        #expect(DiscordActivity(timestamps: .init(start: 1)).sanitized().timestamps == .init(start: 1))
        #expect(DiscordActivity(details: "Game").sanitized().timestamps == nil)
    }

    @Test func sanitizedIsIdempotent() {
        let activity = DiscordActivity(
            details: "d",
            state: " " + String(repeating: "\u{1F63A}", count: 70),
            timestamps: .init(start: 1_727_000_000_000),
            assets: .init(largeImage: " key ", largeText: "t")
        )
        #expect(activity.sanitized().sanitized() == activity.sanitized())
    }

    /// `value` as JSON with sorted keys, as `DiscordFrame` encodes it.
    private func json(_ value: some Encodable) throws -> String {
        String(decoding: try DiscordFrame(opcode: .frame, json: value).payload, as: UTF8.self)
    }
}

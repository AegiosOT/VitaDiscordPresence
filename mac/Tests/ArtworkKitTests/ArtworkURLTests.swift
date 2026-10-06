import Foundation
import Testing
@testable import ArtworkKit

struct ArtworkURLTests {
    // MARK: URL rules

    @Test(arguments: [
        "https://raw.githubusercontent.com/Andiweli/HexFlow-Covers/main/Covers/PSVita/PCSE00120.png",
        "https://robin994.github.io/NeoVitaDB-Catalog/icons/0047-adrenaline.png",
        "HTTPS://EXAMPLE.COM/A.PNG",
        "https://example.com/" + String(repeating: "a", count: 236),
    ])
    func acceptableURLs(_ text: String) throws {
        #expect(ArtworkURL.isAcceptable(try #require(URL(string: text))))
    }

    @Test(arguments: [
        "http://example.com/a.png",
        "ftp://example.com/a.png",
        "file:///tmp/a.png",
        "https:///a.png",
        "https://example.com/a.png?w=512&h=512",
        "https://example.com/a.png?",
        "https://example.com/a.png#fragment",
        "https://example.com/" + String(repeating: "a", count: 237),
        "mp:external/abc/https/example.com/a.png",
        "vita",
    ])
    func unacceptableURLs(_ text: String) throws {
        #expect(!ArtworkURL.isAcceptable(try #require(URL(string: text))))
    }

    @Test func percentEncodedSpacesAreNotWhitespace() throws {
        #expect(ArtworkURL.isAcceptable(try #require(URL(string: "https://example.com/a%20b.png"))))
    }

    @Test(arguments: [("PCSE00120", true), ("VITASHELL", true), ("xmb", true), ("", false), ("A B", false),
                      ("A/B", false), ("Ü1", false), ("A-B", false)])
    func plainIdentifiers(text: String, isPlain: Bool) {
        #expect(ArtworkURL.isPlainIdentifier(text) == isPlain)
    }

    // MARK: HexFlow

    @Test func hexFlowCoverURLs() {
        #expect(HexFlowCovers.coverURL(titleID: "PCSE00120", in: .vita)?.absoluteString
            == "https://raw.githubusercontent.com/Andiweli/HexFlow-Covers/main/Covers/PSVita/PCSE00120.png")
        #expect(HexFlowCovers.coverURL(titleID: "UCUS98711", in: .psp)?.absoluteString
            == "https://raw.githubusercontent.com/Andiweli/HexFlow-Covers/main/Covers/PSP/UCUS98711.png")
        #expect(HexFlowCovers.coverURL(titleID: "SLUS00594", in: .ps1)?.absoluteString
            == "https://raw.githubusercontent.com/Andiweli/HexFlow-Covers/main/Covers/PS1/SLUS00594.png")
        #expect(HexFlowCovers.coverURL(titleID: "../../x", in: .vita) == nil)
        #expect(HexFlowCovers.coverURL(titleID: "", in: .vita) == nil)
    }

    // MARK: Cache

    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let cover = URL(string: "https://example.com/cover.png")!

    @Test func hitsLast30Days() {
        var cache = ArtworkCache()
        cache.record(.found(cover), for: "SLUS00594", at: start)
        #expect(cache.result(for: "SLUS00594", at: start) == .found(cover))
        #expect(cache.result(for: "SLUS00594", at: start + ArtworkCache.hitLifetime - 1) == .found(cover))
        #expect(cache.result(for: "SLUS00594", at: start + ArtworkCache.hitLifetime) == nil)
        #expect(ArtworkCache.hitLifetime == 30 * 86_400)
    }

    @Test func missesLast3Days() {
        var cache = ArtworkCache()
        cache.record(.nothing, for: "PCSE99999", at: start)
        #expect(cache.result(for: "PCSE99999", at: start + ArtworkCache.missLifetime - 1) == .nothing)
        #expect(cache.result(for: "PCSE99999", at: start + ArtworkCache.missLifetime) == nil)
        #expect(ArtworkCache.missLifetime == 3 * 86_400)
    }

    @Test func unknownKeysAndTheFutureHaveNoResult() {
        var cache = ArtworkCache()
        cache.record(.found(cover), for: "SLUS00594", at: start)
        #expect(cache.result(for: "SLUS00595", at: start) == nil)
        #expect(cache.result(for: "SLUS00594", at: start - 1) == nil)
    }

    @Test func removeExpiredKeepsFreshEntries() {
        var cache = ArtworkCache()
        cache.record(.found(cover), for: "OLDHIT001", at: start)
        cache.record(.nothing, for: "OLDMISS01", at: start + 27 * 86_400)
        cache.record(.nothing, for: "NEWMISS01", at: start + 29 * 86_400)
        cache.removeExpired(at: start + 31 * 86_400)
        #expect(cache.entries.keys.sorted() == ["NEWMISS01"])
    }

    @Test func saveAndLoadRoundTrip() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("nested/artwork.json")
        var cache = ArtworkCache()
        cache.record(.found(cover), for: "SLUS00594", at: start + 0.25)
        cache.record(.nothing, for: "PCSE00120|UP0082-PCSE00120_00-PERSONA4GOLDEN01", at: start)
        cache.save(to: file)
        let loaded = ArtworkCache.load(from: file)
        #expect(loaded.entries == cache.entries)
        #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("\\/"))
    }

    @Test func loadingAMissingFileGivesAnEmptyCache() {
        #expect(ArtworkCache.load(from: URL(fileURLWithPath: "/nonexistent/artwork.json")).entries.isEmpty)
    }

    // MARK: HTTPResponse

    @Test(arguments: [
        ("image/png", "image/png"), ("image/jpeg;charset=UTF-8", "image/jpeg"), (" Image/PNG ; x=y", "image/png"),
    ])
    func mediaType(header: String, mediaType: String) {
        #expect(HTTPResponse(status: 200, headers: ["content-type": header]).mediaType == mediaType)
    }

    @Test func mediaTypeNeedsAContentType() {
        #expect(HTTPResponse(status: 200).mediaType == nil)
        #expect(HTTPResponse(status: 200, headers: ["content-type": ""]).mediaType == nil)
    }

    @Test(arguments: [(200, true), (302, true), (404, true), (410, true), (403, true), (408, false), (429, false),
                      (500, false), (503, false)])
    func definitiveStatuses(status: Int, isDefinitive: Bool) {
        #expect(HTTPResponse(status: status).isDefinitive == isDefinitive)
    }
}

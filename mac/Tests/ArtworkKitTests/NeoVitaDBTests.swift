import Foundation
import Testing
@testable import ArtworkKit

private typealias Entry = NeoVitaDB.Entry

struct NeoVitaDBTests {
    @Test func parsesThePublishedCatalog() throws {
        // Shape of the real vita.json (trimmed): every value is a string.
        let body = """
            [{"name":"VitaShell","icon":"0021-vitashell.png","version":"v2.2","author":"TheFloW","type":"4","id":"21",
            "date":"2026-01-01","titleid":"VITASHELL","downloads":"100","url":"https://example.com/VitaShell.vpk"},
            {"name":"Adrenaline","icon":"0047-adrenaline.png","titleid":"PSPEMUCFW","id":"47","type":"4"}]
            """
        #expect(try NeoVitaDB.parseCatalog(Data(body.utf8)) == [
            Entry(titleID: "VITASHELL", name: "VitaShell", icon: "0021-vitashell.png"),
            Entry(titleID: "PSPEMUCFW", name: "Adrenaline", icon: "0047-adrenaline.png"),
        ])
    }

    @Test func skipsEntriesWithoutATitleIDOrIcon() throws {
        let body = """
            [{"name":"No ID","icon":"1.png"},{"name":"Empty ID","icon":"2.png","titleid":"  "},
            {"name":"No icon","titleid":"NOICON001"},{"name":"Empty icon","titleid":"NOICON002","icon":""},
            {"name":"Odd types","titleid":42,"icon":"3.png"},null,"text",
            {"icon":"4.png","titleid":" lower001 "}]
            """
        #expect(try NeoVitaDB.parseCatalog(Data(body.utf8)) == [Entry(titleID: "LOWER001", name: "", icon: "4.png")])
    }

    @Test(arguments: ["", "{}", #"{"apps":[]}"#, "<!doctype html>"])
    func aBodyThatIsNotACatalogThrows(_ body: String) {
        #expect(throws: (any Error).self) { try NeoVitaDB.parseCatalog(Data(body.utf8)) }
    }

    @Test func iconURL() {
        let entry = Entry(titleID: "PSPEMUCFW", name: "Adrenaline", icon: "0047-adrenaline.png")
        #expect(NeoVitaDB.iconURL(for: entry)?.absoluteString
            == "https://robin994.github.io/NeoVitaDB-Catalog/icons/0047-adrenaline.png")
    }

    @Test(arguments: [
        "", "my icon.png", "a?b.png", "a#b.png", "../a.png", ".a.png", "-a.png", "a/b.png", "a%20b.png", "ä.png",
    ])
    func iconFileNamesMustBePlain(_ icon: String) {
        #expect(NeoVitaDB.iconURL(for: Entry(titleID: "ODDICON01", name: "Odd", icon: icon)) == nil)
    }

    @Test func catalogFreshness() {
        let fetchedAt = Date(timeIntervalSince1970: 1_790_000_000)
        let catalog = NeoVitaDB.Catalog(fetchedAt: fetchedAt, entries: [])
        #expect(catalog.isFresh(at: fetchedAt))
        #expect(catalog.isFresh(at: fetchedAt + 86_399))
        #expect(!catalog.isFresh(at: fetchedAt + 86_400))
        #expect(!catalog.isFresh(at: fetchedAt - 1))
    }

    @Test func catalogLooksUpByTitleID() {
        let catalog = NeoVitaDB.Catalog(fetchedAt: Date(), entries: [
            Entry(titleID: "VITASHELL", name: "VitaShell", icon: "1.png"),
            Entry(titleID: "ABCD12345", name: "First", icon: "2.png"),
            Entry(titleID: "ABCD12345", name: "Second", icon: "3.png"),
        ])
        #expect(catalog.entries(for: "ABCD12345").map(\.icon) == ["2.png", "3.png"])
        #expect(catalog.entries(for: "VITASHELL").map(\.icon) == ["1.png"])
        #expect(catalog.entries(for: "MISSING00").isEmpty)
    }

    @Test(arguments: [
        ("VitaShell", "VitaShell", NeoVitaDB.NameMatch.equal),
        ("Vita Pong", "VitaPong™", .equal),
        ("ＶＩＴＡＳＨＥＬＬ", "vitashell", .equal),
        ("Pokémon Ruby", "Pokemon ruby", .equal),
        ("Flappy Bird Vita", "Flappy Bird", .contained),
        ("Bird", "Flappy Bird Vita", .contained),
    ])
    func namesThatMatch(lhs: String, rhs: String, match: NeoVitaDB.NameMatch) {
        #expect(NeoVitaDB.nameMatch(lhs, rhs) == match)
        #expect(NeoVitaDB.nameMatch(rhs, lhs) == match)
    }

    @Test(arguments: [
        ("History Deleter", "Ecolibrium"),
        ("Lantern Mouse", "Dragon Quest Builders Demo"),
        ("Box", "Boxing Day"),
        ("VR", "Vita VR Player"),
        ("", "Anything"),
        ("™", "™"),
    ])
    func namesThatDoNotMatch(lhs: String, rhs: String) {
        #expect(NeoVitaDB.nameMatch(lhs, rhs) == nil)
        #expect(NeoVitaDB.nameMatch(rhs, lhs) == nil)
    }

    @Test func candidatesFollowTheNameRule() {
        let catalog = NeoVitaDB.Catalog(fetchedAt: Date(), entries: [
            Entry(titleID: "ONLYONE01", name: "Only One", icon: "only.png"),
            Entry(titleID: "SHARED001", name: "Flappy Bird Vita Deluxe", icon: "deluxe.png"),
            Entry(titleID: "SHARED001", name: "Other Game", icon: "other.png"),
            Entry(titleID: "SHARED001", name: "Flappy Bird", icon: "flappy.png"),
        ])
        func icons(_ titleID: String, _ name: String, _ rule: NeoVitaDB.NameRule) -> [String] {
            NeoVitaDB.candidates(in: catalog, titleID: titleID, name: name, rule: rule).map(\.icon)
        }
        #expect(icons("ONLYONE01", "Something Else", .requiredIfShared) == ["only.png"])
        #expect(icons("ONLYONE01", "Something Else", .required) == [])
        #expect(icons("ONLYONE01", "Only One", .required) == ["only.png"])
        #expect(icons("SHARED001", "Flappy Bird", .requiredIfShared) == ["flappy.png", "deluxe.png"])
        #expect(icons("SHARED001", "Unrelated", .requiredIfShared) == [])
        #expect(icons("SHARED001", "Flappy Bird", .preferred) == ["flappy.png", "deluxe.png", "other.png"])
        #expect(icons("SHARED001", "", .preferred) == ["deluxe.png", "other.png", "flappy.png"])
        #expect(icons("MISSING00", "Flappy Bird", .preferred) == [])
    }

    @Test func storedCatalogRoundTrip() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("neovitadb.json")
        let catalog = NeoVitaDB.Catalog(fetchedAt: Date(timeIntervalSince1970: 1_790_000_000.5), entries: [
            Entry(titleID: "VITASHELL", name: "VitaShell", icon: "0021-vitashell.png"),
        ])
        JSONFile.write(NeoVitaDB.StoredCatalog(catalog), to: file)
        let loaded = try #require(NeoVitaDB.StoredCatalog.load(from: file))
        #expect(loaded.fetchedAt == catalog.fetchedAt)
        #expect(loaded.entries == catalog.entries)
        #expect(loaded.entries(for: "VITASHELL").count == 1)
    }

    @Test func storedCatalogOfAnotherVersionIsIgnored() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("neovitadb.json")
        try Data(#"{"version":2,"fetchedAt":1790000000,"entries":[]}"#.utf8).write(to: file)
        #expect(NeoVitaDB.StoredCatalog.load(from: file) == nil)
        #expect(NeoVitaDB.StoredCatalog.load(from: directory.appendingPathComponent("missing.json")) == nil)
    }
}

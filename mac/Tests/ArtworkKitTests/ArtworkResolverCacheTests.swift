import Foundation
import Testing
import VitaKit
@testable import ArtworkKit

/// `ArtworkResolver` caching: lifetimes, the cache file, the NeoVitaDB catalog, shared lookups and failures.
struct ArtworkResolverCacheTests {
    let http = FakeHTTPClient()
    let clock = TestClock()

    private var metalGearCover: String { hexFlowCover("PS1", "SLUS00594") }

    // MARK: Lifetimes

    @Test func hitsAreKeptFor30Days() async {
        http.on(.head, metalGearCover, .image)
        let resolver = makeResolver(http, clock: clock)
        #expect(await resolver.artwork(for: metalGear)?.absoluteString == metalGearCover)
        let requests = http.requests.count

        clock.advance(days: 29, hours: 23)
        #expect(await resolver.artwork(for: metalGear)?.absoluteString == metalGearCover)
        #expect(http.requests.count == requests)

        clock.advance(hours: 1, seconds: 1)
        #expect(await resolver.artwork(for: metalGear)?.absoluteString == metalGearCover)
        #expect(http.requests.count > requests)
    }

    @Test func missesAreKeptFor3Days() async {
        http.on(.get, catalogURL, .json(standardCatalog))
        let resolver = makeResolver(http, clock: clock)
        #expect(await resolver.artwork(for: metalGear) == nil)
        let requests = http.requests.count
        #expect(requests > 0)

        clock.advance(days: 2, hours: 23)
        #expect(await resolver.artwork(for: metalGear) == nil)
        #expect(http.requests.count == requests)

        clock.advance(hours: 1, seconds: 1)
        http.on(.head, metalGearCover, .image)
        #expect(await resolver.artwork(for: metalGear)?.absoluteString == metalGearCover)
    }

    @Test func entriesFromTheFutureCountAsExpired() async {
        http.on(.head, metalGearCover, .image)
        let resolver = makeResolver(http, clock: clock)
        _ = await resolver.artwork(for: metalGear)
        let requests = http.requests.count
        clock.advance(seconds: -60)
        _ = await resolver.artwork(for: metalGear)
        #expect(http.requests.count > requests)
    }

    @Test func theContentIDIsPartOfTheKey() async {
        let sfoContentID = "UP0082-PCSE00120_00-PERSONA4GOLDEN01"
        http.on(.head, storeImage(sfoContentID), .image)
        http.on(.head, hexFlowCover("PSVita", "PCSE00120"), .image)
        let resolver = makeResolver(http, clock: clock)
        let withContentID = makeTitle("PCSE00120", "Persona 4 Golden", contentID: sfoContentID)
        #expect(await resolver.artwork(for: withContentID)?.absoluteString == storeImage(sfoContentID))
        #expect(await resolver.artwork(for: personaUS)?.absoluteString == hexFlowCover("PSVita", "PCSE00120"))
        #expect(await resolver.artwork(for: withContentID)?.absoluteString == storeImage(sfoContentID))
        #expect(http.count(.head, storeImage(sfoContentID)) == 1)
    }

    @Test func titleIDsAreComparedWithoutCaseOrSurroundingSpaces() async {
        http.on(.head, metalGearCover, .image)
        let resolver = makeResolver(http, clock: clock)
        _ = await resolver.artwork(for: metalGear)
        let spaced = makeTitle(" slus00594 ", "Metal Gear Solid")
        #expect(await resolver.artwork(for: spaced)?.absoluteString == metalGearCover)
        #expect(http.count(.head, metalGearCover) == 1)
    }

    // MARK: Failures

    @Test(arguments: [
        FakeHTTPClient.Reply.offline,
        .failure(.timedOut),
        .failure(.secureConnectionFailed),
        .status(500),
        .status(503),
        .status(408),
        .status(429),
    ])
    func aProbeThatCouldNotBeAnsweredIsNotCached(_ reply: FakeHTTPClient.Reply) async {
        http.on(.head, metalGearCover, reply)
        http.on(.get, catalogURL, .json(standardCatalog))
        let resolver = makeResolver(http, clock: clock)
        #expect(await resolver.artwork(for: metalGear) == nil)
        http.on(.head, metalGearCover, .image)
        #expect(await resolver.artwork(for: metalGear)?.absoluteString == metalGearCover)
    }

    @Test(arguments: [
        FakeHTTPClient.Reply.offline,
        .status(502),
        .json("<html>Service Unavailable</html>"),
        .json(#"{"links": 7}"#),
        .json("[]"),
    ])
    func aSearchThatCouldNotBeAnsweredIsNotCached(_ reply: FakeHTTPClient.Reply) async {
        http.on(.get, storeSearch("Persona%204%20Golden"), reply)
        http.on(.get, catalogURL, .json(standardCatalog))
        let resolver = makeResolver(http, clock: clock)
        #expect(await resolver.artwork(for: personaUS) == nil)
        http.on(.get, storeSearch("Persona%204%20Golden"), .json(searchResponse([
            (personaUSStoreID, "Persona®4 Golden™", "downloadable_game"),
        ])))
        http.on(.head, storeImage(personaUSStoreID), .image)
        #expect(await resolver.artwork(for: personaUS)?.absoluteString == storeImage(personaUSStoreID))
    }

    @Test(arguments: [
        FakeHTTPClient.Reply.status(404),
        .status(403),
        .json(#"{"size":0}"#),
        .json(searchResponse()),
    ])
    func aSearchThatAnsweredIsPartOfACachedMiss(_ reply: FakeHTTPClient.Reply) async {
        http.on(.get, storeSearch("Persona%204%20Golden"), reply)
        http.on(.get, catalogURL, .json(standardCatalog))
        let resolver = makeResolver(http, clock: clock)
        #expect(await resolver.artwork(for: personaUS) == nil)
        let requests = http.requests.count
        #expect(await resolver.artwork(for: personaUS) == nil)
        #expect(http.requests.count == requests)
    }

    @Test func anUnansweredSourceDoesNotHideALaterHit() async {
        http.on(.get, storeSearch("Persona%204%20Golden"), .offline)
        http.on(.head, hexFlowCover("PSVita", "PCSE00120"), .image)
        let resolver = makeResolver(http, clock: clock)
        #expect(await resolver.artwork(for: personaUS)?.absoluteString == hexFlowCover("PSVita", "PCSE00120"))
        let requests = http.requests.count
        #expect(await resolver.artwork(for: personaUS)?.absoluteString == hexFlowCover("PSVita", "PCSE00120"))
        #expect(http.requests.count == requests)
    }

    // MARK: Cache file

    @Test func resultsSurviveARestart() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheFile = directory.appendingPathComponent("artwork.json")
        http.on(.head, metalGearCover, .image)
        http.on(.get, catalogURL, .json(standardCatalog))
        let first = makeResolver(http, cacheFile: cacheFile, clock: clock)
        #expect(await first.artwork(for: metalGear)?.absoluteString == metalGearCover)
        #expect(await first.artwork(for: personaUS) == nil)

        let offline = FakeHTTPClient()
        let second = makeResolver(offline, cacheFile: cacheFile, clock: clock)
        #expect(await second.artwork(for: metalGear)?.absoluteString == metalGearCover)
        #expect(await second.artwork(for: personaUS) == nil)
        #expect(offline.requests.isEmpty)
    }

    @Test func theCacheFileIsReadableJSON() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheFile = directory.appendingPathComponent("artwork.json")
        http.on(.head, storeImage(personaUSStoreID), .image)
        _ = await makeResolver(http, cacheFile: cacheFile, clock: clock)
            .artwork(for: makeTitle("PCSE00120", "Persona 4 Golden", contentID: personaUSStoreID))
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: cacheFile)) as? [String: Any]
        )
        let entries = try #require(json["entries"] as? [String: [String: Any]])
        let entry = try #require(entries["PCSE00120|\(personaUSStoreID)"])
        #expect(entry["url"] as? String == storeImage(personaUSStoreID))
        #expect(entry["checkedAt"] as? Double == clock.now.timeIntervalSince1970)
        #expect(json["version"] as? Int == 1)
    }

    @Test func expiredResultsReloadedFromTheFileAreLookedUpAgain() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheFile = directory.appendingPathComponent("artwork.json")
        http.on(.head, metalGearCover, .image)
        _ = await makeResolver(http, cacheFile: cacheFile, clock: clock).artwork(for: metalGear)
        clock.advance(days: 31)
        let later = FakeHTTPClient()
        later.on(.head, metalGearCover, .image)
        #expect(await makeResolver(later, cacheFile: cacheFile, clock: clock).artwork(for: metalGear) != nil)
        #expect(later.count(.head, metalGearCover) == 1)
    }

    @Test func theCacheDirectoryIsCreated() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheFile = directory.appendingPathComponent("Caches/io.github.aegiosot.VitaPresence/artwork.json")
        http.on(.head, metalGearCover, .image)
        _ = await makeResolver(http, cacheFile: cacheFile, clock: clock).artwork(for: metalGear)
        #expect(FileManager.default.fileExists(atPath: cacheFile.path))
    }

    @Test(arguments: ["not json", "", #"{"version":1,"entries":[]}"#, #"{"version":99,"entries":{}}"#])
    func aCorruptCacheFileIsIgnoredAndReplaced(_ contents: String) async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheFile = directory.appendingPathComponent("artwork.json")
        try Data(contents.utf8).write(to: cacheFile)
        http.on(.head, metalGearCover, .image)
        #expect(await makeResolver(http, cacheFile: cacheFile, clock: clock).artwork(for: metalGear) != nil)

        let offline = FakeHTTPClient()
        #expect(await makeResolver(offline, cacheFile: cacheFile, clock: clock).artwork(for: metalGear) != nil)
        #expect(offline.requests.isEmpty)
    }

    @Test func cachedURLsThatBreakTheRulesAreDropped() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheFile = directory.appendingPathComponent("artwork.json")
        let checkedAt = clock.now.timeIntervalSince1970
        let stored = """
            {"version":1,"entries":{
            "SLUS00594":{"url":"http://example.com/cover.png","checkedAt":\(checkedAt)},
            "VITASHELL":{"url":"https://example.com/icon.png?size=128","checkedAt":\(checkedAt)},
            "PCSE00120":{"url":"https://example.com/p4g.png","checkedAt":\(checkedAt)}}}
            """
        try Data(stored.utf8).write(to: cacheFile)
        let resolver = makeResolver(http, cacheFile: cacheFile, clock: clock)
        #expect(await resolver.artwork(for: personaUS)?.absoluteString == "https://example.com/p4g.png")
        #expect(await resolver.artwork(for: metalGear) == nil)
        #expect(await resolver.artwork(for: vitaShell) == nil)
        #expect(http.log.contains("HEAD \(metalGearCover)"))
        #expect(http.log.contains("GET \(catalogURL)"))
    }

    @Test func expiredEntriesArePrunedFromTheFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheFile = directory.appendingPathComponent("artwork.json")
        http.on(.head, metalGearCover, .image)
        http.on(.head, hexFlowCover("PS1", "SCES00344"), .image)
        let resolver = makeResolver(http, cacheFile: cacheFile, clock: clock)
        _ = await resolver.artwork(for: metalGear)
        clock.advance(days: 31)
        _ = await resolver.artwork(for: makeTitle("SCES00344", "Crash Bandicoot"))
        let contents = try String(contentsOf: cacheFile, encoding: .utf8)
        #expect(contents.contains("SCES00344"))
        #expect(!contents.contains("SLUS00594"))
    }

    // MARK: Shared lookups

    @Test func concurrentRequestsForTheSameTitleShareOneLookup() async {
        let gate = Gate()
        http.on(.get, catalogURL, .status(404))
        http.on(.head, metalGearCover, .held(gate, .image))
        let resolver = makeResolver(http, clock: clock)
        let first = Task { await resolver.artwork(for: metalGear) }
        #expect(await eventually { http.count(.head, metalGearCover) == 1 })
        let second = Task { await resolver.artwork(for: metalGear) }
        let third = Task { await resolver.artwork(for: makeTitle("SLUS00594", "METAL GEAR SOLID")) }
        #expect(await eventually { await resolver.joinedLookups >= 2 })
        gate.open()
        #expect(await first.value?.absoluteString == metalGearCover)
        #expect(await second.value?.absoluteString == metalGearCover)
        #expect(await third.value?.absoluteString == metalGearCover)
        #expect(http.count(.head, metalGearCover) == 1)
        #expect(http.count(.get, catalogURL) == 1)
    }

    @Test func differentTitlesAreLookedUpSeparately() async {
        let gate = Gate()
        http.on(.head, metalGearCover, .held(gate, .image))
        http.on(.head, hexFlowCover("PS1", "SCES00344"), .image)
        let resolver = makeResolver(http, clock: clock)
        let held = Task { await resolver.artwork(for: metalGear) }
        #expect(await eventually { http.count(.head, metalGearCover) == 1 })
        // A lookup for another title isn't stuck behind the held one.
        #expect(await resolver.artwork(for: makeTitle("SCES00344", "Crash Bandicoot")) != nil)
        gate.open()
        #expect(await held.value != nil)
    }

    @Test func aSharedLookupThatFailsIsRetriedByTheNextCall() async {
        let gate = Gate()
        http.on(.head, metalGearCover, .held(gate, .offline))
        let resolver = makeResolver(http, clock: clock)
        let first = Task { await resolver.artwork(for: metalGear) }
        #expect(await eventually { http.count(.head, metalGearCover) == 1 })
        let second = Task { await resolver.artwork(for: metalGear) }
        #expect(await eventually { await resolver.joinedLookups >= 1 })
        gate.open()
        #expect(await first.value == nil)
        #expect(await second.value == nil)
        http.on(.head, metalGearCover, .image)
        #expect(await resolver.artwork(for: metalGear) != nil)
        #expect(http.count(.head, metalGearCover) == 2)
    }

    // MARK: NeoVitaDB catalog

    @Test func theCatalogIsFetchedAtMostOnceADay() async {
        http.on(.get, catalogURL, .json(standardCatalog))
        http.on(.head, catalogIcon("0021-vitashell.png"), .image)
        http.on(.head, catalogIcon("1534-retroarch.png"), .image)
        http.on(.head, catalogIcon("0047-adrenaline.png"), .image)
        let resolver = makeResolver(http, clock: clock)
        #expect(await resolver.artwork(for: vitaShell) != nil)
        clock.advance(hours: 23)
        #expect(await resolver.artwork(for: makeTitle("RETROVITA", "RetroArch")) != nil)
        #expect(http.count(.get, catalogURL) == 1)
        clock.advance(hours: 1, seconds: 1)
        #expect(await resolver.artwork(for: adrenalineMenu) != nil)
        #expect(http.count(.get, catalogURL) == 2)
    }

    @Test func theCatalogIsKeptNextToTheCacheFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheFile = directory.appendingPathComponent("artwork.json")
        http.on(.get, catalogURL, .json(standardCatalog))
        http.on(.head, catalogIcon("0021-vitashell.png"), .image)
        _ = await makeResolver(http, cacheFile: cacheFile, clock: clock).artwork(for: vitaShell)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("neovitadb.json").path))

        clock.advance(hours: 2)
        let restarted = FakeHTTPClient()
        restarted.on(.head, catalogIcon("1534-retroarch.png"), .image)
        let found = await makeResolver(restarted, cacheFile: cacheFile, clock: clock)
            .artwork(for: makeTitle("RETROVITA", "RetroArch"))
        #expect(found?.absoluteString == catalogIcon("1534-retroarch.png"))
        #expect(restarted.log == ["HEAD \(catalogIcon("1534-retroarch.png"))"])
    }

    @Test func aCatalogFileOlderThanADayIsRefreshed() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheFile = directory.appendingPathComponent("artwork.json")
        http.on(.get, catalogURL, .json(standardCatalog))
        _ = await makeResolver(http, cacheFile: cacheFile, clock: clock).artwork(for: vitaShell)

        clock.advance(hours: 25)
        let restarted = FakeHTTPClient()
        restarted.on(.get, catalogURL, .json(catalogBody([("NEWAPP001", "New App", "2000-new-app.png")])))
        restarted.on(.head, catalogIcon("2000-new-app.png"), .image)
        let found = await makeResolver(restarted, cacheFile: cacheFile, clock: clock)
            .artwork(for: makeTitle("NEWAPP001", "New App"))
        #expect(found?.absoluteString == catalogIcon("2000-new-app.png"))
        #expect(restarted.count(.get, catalogURL) == 1)
    }

    @Test(arguments: ["{]", #"{"entries":"oops"}"#])
    func aCorruptCatalogFileIsIgnored(_ contents: String) async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(contents.utf8).write(to: directory.appendingPathComponent("neovitadb.json"))
        http.on(.get, catalogURL, .json(standardCatalog))
        http.on(.head, catalogIcon("0021-vitashell.png"), .image)
        let resolver = makeResolver(http, cacheFile: directory.appendingPathComponent("artwork.json"), clock: clock)
        #expect(await resolver.artwork(for: vitaShell)?.absoluteString == catalogIcon("0021-vitashell.png"))
        #expect(http.count(.get, catalogURL) == 1)
    }

    @Test func anOldCatalogIsUsedWhenItCannotBeRefreshed() async {
        http.on(.get, catalogURL, .json(standardCatalog))
        http.on(.head, catalogIcon("0021-vitashell.png"), .image)
        http.on(.head, catalogIcon("1534-retroarch.png"), .image)
        let resolver = makeResolver(http, clock: clock)
        _ = await resolver.artwork(for: vitaShell)
        clock.advance(days: 2)
        http.on(.get, catalogURL, .offline)
        let found = await resolver.artwork(for: makeTitle("RETROVITA", "RetroArch"))
        #expect(found?.absoluteString == catalogIcon("1534-retroarch.png"))
        #expect(http.count(.get, catalogURL) == 2)
    }

    @Test func withoutACatalogThatSourceIsSkipped() async {
        http.on(.get, catalogURL, .offline)
        http.on(.head, hexFlowCover("PSVita", "VITASHELL"), .image)
        #expect(await makeResolver(http, clock: clock).artwork(for: vitaShell)?.absoluteString
            == hexFlowCover("PSVita", "VITASHELL"))
    }

    @Test(arguments: [
        FakeHTTPClient.Reply.offline,
        .status(500),
        .json("<!doctype html>"),
        .json(#"{"apps":[]}"#),
    ])
    func aCatalogThatCouldNotBeFetchedIsTriedAgainFiveMinutesLater(_ reply: FakeHTTPClient.Reply) async {
        http.on(.get, catalogURL, reply)
        let resolver = makeResolver(http, clock: clock)
        #expect(await resolver.artwork(for: adrenalineMenu) == nil)
        http.on(.get, catalogURL, .json(standardCatalog))
        http.on(.head, catalogIcon("0047-adrenaline.png"), .image)

        // The miss wasn't cached, but the catalog isn't fetched again right away.
        clock.advance(minutes: 4)
        #expect(await resolver.artwork(for: adrenalineMenu) == nil)
        #expect(http.count(.get, catalogURL) == 1)

        clock.advance(minutes: 1)
        #expect(await resolver.artwork(for: adrenalineMenu)?.absoluteString == catalogIcon("0047-adrenaline.png"))
        #expect(http.count(.get, catalogURL) == 2)
    }

    @Test func anOldCatalogServesWhileARefreshIsDue() async {
        http.on(.get, catalogURL, .json(standardCatalog))
        http.on(.head, catalogIcon("0021-vitashell.png"), .image)
        http.on(.head, catalogIcon("1534-retroarch.png"), .image)
        http.on(.head, catalogIcon("0047-adrenaline.png"), .image)
        let resolver = makeResolver(http, clock: clock)
        _ = await resolver.artwork(for: vitaShell)
        clock.advance(days: 2)
        http.on(.get, catalogURL, .status(503))
        #expect(await resolver.artwork(for: makeTitle("RETROVITA", "RetroArch")) != nil)
        clock.advance(minutes: 1)
        #expect(await resolver.artwork(for: adrenalineMenu) != nil)
        #expect(http.count(.get, catalogURL) == 2)
    }

    @Test func aCatalogThatIsGoneMeansNoIcons() async {
        http.on(.get, catalogURL, .status(404))
        let resolver = makeResolver(http, clock: clock)
        #expect(await resolver.artwork(for: adrenalineMenu) == nil)
        #expect(await resolver.artwork(for: adrenalineMenu) == nil)
        #expect(http.count(.get, catalogURL) == 1)
    }

    @Test func concurrentLookupsShareOneCatalogFetch() async {
        let gate = Gate()
        http.on(.get, catalogURL, .held(gate, .json(standardCatalog)))
        http.on(.head, catalogIcon("0021-vitashell.png"), .image)
        http.on(.head, catalogIcon("0047-adrenaline.png"), .image)
        let resolver = makeResolver(http, clock: clock)
        let shell = Task { await resolver.artwork(for: vitaShell) }
        #expect(await eventually { http.count(.get, catalogURL) == 1 })
        let menu = Task { await resolver.artwork(for: adrenalineMenu) }
        try? await Task.sleep(for: .milliseconds(100))
        gate.open()
        #expect(await shell.value?.absoluteString == catalogIcon("0021-vitashell.png"))
        #expect(await menu.value?.absoluteString == catalogIcon("0047-adrenaline.png"))
        #expect(http.count(.get, catalogURL) == 1)
    }
}

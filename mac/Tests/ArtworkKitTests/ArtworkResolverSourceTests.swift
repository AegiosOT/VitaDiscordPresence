import Foundation
import Testing
import VitaKit
@testable import ArtworkKit

/// Which sources `ArtworkResolver` asks for each kind of title, in which order, and what it accepts.
struct ArtworkResolverSourceTests {
    let http = FakeHTTPClient()
    let liberty = makeTitle("ULUS10041", "Grand Theft Auto: Liberty City Stories")

    // MARK: Titles without artwork

    @Test(arguments: [
        VitaTitle.liveArea,
        makeTitle("NPXS10015", "Settings"),
        makeTitle("NPXS10015", "Settings", contentID: "UP0000-NPXS10015_00-0000000000000000"),
        makeTitle("", "Nameless"),
        makeTitle("  ", ""),
    ])
    func liveAreaAndSystemAppsHaveNoArtworkAndCostNoRequests(_ title: VitaTitle) async {
        #expect(await makeResolver(http).artwork(for: title) == nil)
        #expect(http.requests.isEmpty)
    }

    // MARK: Content ID

    @Test(arguments: [
        ("PCSE00120", "UP0005-PCSE00120_00-PERSONA4GOLDEN01", "US", "en"),
        ("PCSB00245", "EP1063-PCSB00245_00-PERSONA4GOLDEN01", "GB", "en"),
        ("PCSG00563", "JP0005-PCSG00563_00-PERSONA4GOLDEN01", "JP", "ja"),
        ("PCSD00003", "HP9000-PCSD00003_00-PDHKAP1633013602", "SG", "en"),
        ("PCSH00021", "KP0001-PCSH00021_00-KOREANEDITION000", "KR", "ko"),
        ("PCSE00491", "IP4433-PCSE00491_00-MINECRAFTVIT0000", "US", "en"),
    ])
    func contentIDGivesTheStoreImageInItsStorefront(
        titleID: String,
        contentID: String,
        country: String,
        language: String
    ) async {
        let image = storeImage(contentID, country, language)
        http.on(.head, image, .image)
        let found = await makeResolver(http).artwork(for: makeTitle(titleID, "Game", contentID: contentID))
        #expect(found?.absoluteString == image)
        #expect(http.log == ["HEAD \(image)"])
    }

    @Test func storeImageURLHasTheProvenForm() async {
        let image = storeImage(personaUSStoreID)
        http.on(.head, image, .image)
        let found = await makeResolver(http).artwork(for: makeTitle("PCSE00120", "P4G", contentID: personaUSStoreID))
        #expect(found?.absoluteString == """
            https://store.playstation.com/store/api/chihiro/00_09_000/container/US/en/19/\
            UP0005-PCSE00120_00-PERSONA4GOLDEN01/1534563384000/image
            """)
        #expect(found?.absoluteString.count == 133)
    }

    @Test func malformedContentIDIsIgnored() async {
        let malformed = makeTitle("PCSE00120", "", contentID: "UP0005-PCSE00120-PERSONA4GOLDEN01")
        _ = await makeResolver(http).artwork(for: malformed)
        #expect(!http.log.contains { $0.contains("/container/") })
        #expect(http.log == ["HEAD \(hexFlowCover("PSVita", "PCSE00120"))"])
    }

    @Test func storeNotFoundFallsBackToTheSearch() async {
        let sfoContentID = "UP0082-PCSE00120_00-PERSONA4GOLDEN01"
        http.on(.get, storeSearch("Persona%204%20Golden"), .json(searchResponse([
            ("UP0177-CUSA33873_00-DAYLIGHT00000000", "Persona 4 Golden", "downloadable_game"),
            (personaUSStoreID, "Persona®4 Golden™", "downloadable_game"),
        ])))
        http.on(.head, storeImage(personaUSStoreID), .image)
        let resolver = makeResolver(http)
        let found = await resolver.artwork(for: makeTitle("PCSE00120", "Persona 4 Golden", contentID: sfoContentID))
        #expect(found?.absoluteString == storeImage(personaUSStoreID))
        #expect(http.log == [
            "HEAD \(storeImage(sfoContentID))",
            "GET \(storeSearch("Persona%204%20Golden"))",
            "HEAD \(storeImage(personaUSStoreID))",
        ])
    }

    // MARK: Store search

    @Test func searchFindsTheStoreImageWithoutAContentID() async {
        http.on(.get, storeSearch("Persona%204%20Golden"), .json(searchResponse([
            (personaUSStoreID, "Persona®4 Golden™", "downloadable_game"),
        ])))
        http.on(.head, storeImage(personaUSStoreID), .image)
        #expect(await makeResolver(http).artwork(for: personaUS)?.absoluteString == storeImage(personaUSStoreID))
        #expect(http.log == ["GET \(storeSearch("Persona%204%20Golden"))", "HEAD \(storeImage(personaUSStoreID))"])
    }

    @Test(arguments: [
        ("PCSA00011", "US", "en"), ("PCSE00491", "US", "en"),
        ("PCSB00245", "GB", "en"), ("PCSF00243", "GB", "en"),
        ("PCSC00045", "JP", "ja"), ("PCSG00563", "JP", "ja"),
        ("PCSD00003", "SG", "en"), ("PCSH10001", "SG", "en"),
        ("ULUS10041", "US", "en"), ("UCUS98711", "US", "en"), ("NPUH10091", "US", "en"),
        ("ULES01213", "GB", "en"), ("UCES00001", "GB", "en"), ("NPEZ00001", "GB", "en"),
        ("ULJM05800", "JP", "ja"), ("ULJS00001", "JP", "ja"), ("UCJS10041", "JP", "ja"), ("NPJH50465", "JP", "ja"),
        ("ULAS42019", "SG", "en"), ("NPHH00123", "SG", "en"),
        ("ULKS46164", "KR", "ko"), ("NPKH00001", "KR", "ko"),
    ])
    func searchAndImageUseTheTitleIDsStorefront(titleID: String, country: String, language: String) async {
        let contentID = "XX0000-\(titleID)_00-GAME000000000000"
        http.on(.get, storeSearch("Some%20Game", country, language), .json(searchResponse([
            (contentID, "Some Game", "downloadable_game"),
        ])))
        http.on(.head, storeImage(contentID, country, language), .image)
        let found = await makeResolver(http).artwork(for: makeTitle(titleID, "Some Game"))
        #expect(found?.absoluteString == storeImage(contentID, country, language))
    }

    @Test func searchAcceptsOnlyTheExactTitleID() async {
        http.on(.get, storeSearch("Persona%204%20Golden"), .json(searchResponse([
            ("UP0177-CUSA33873_00-DAYLIGHT00000000", "Persona 4 Golden", "downloadable_game"),
            ("UP0005-PCSE00121_00-PERSONA4GOLDEN01", "Persona 4 Golden", "downloadable_game"),
            ("UP0005-PCSE00120_01-PERSONA4GOLDEN01", "Persona 4 Golden", "downloadable_game"),
            ("UP0005-XPCSE00120_00-PERSONA4GOLDEN", "Persona 4 Golden", "downloadable_game"),
            ("UP0005-PCSE00120_00-PERSONA4GOLDEN", "Persona 4 Golden", "downloadable_game"),
            ("UP0005-PCSE00120_00-COSTUMEPACK00001", "Persona 4 Golden Costumes", "add_on"),
        ])))
        let found = await makeResolver(http).artwork(for: personaUS)
        #expect(found == nil)
        // No store image was probed: none of those products is P4G US itself.
        #expect(!http.log.contains { $0.hasPrefix("HEAD \(storeAPI)") })
        #expect(http.log.contains("HEAD \(hexFlowCover("PSVita", "PCSE00120"))"))
    }

    @Test func searchTriesShorterQueriesUntilOneFindsTheTitle() async {
        let killzone = "EP9000-PCSF00243_00-KZV0000000000000"
        http.on(.get, storeSearch("Killzone%3A%20Mercenary", "GB"), .json(searchResponse()))
        http.on(.get, storeSearch("Killzone", "GB"), .json(searchResponse([
            ("EP9000-CUSA00002_00-KZSHADOWFALL0000", "Killzone Shadow Fall", "downloadable_game"),
            (killzone, "Killzone™: Mercenary", "downloadable_game"),
        ])))
        http.on(.head, storeImage(killzone, "GB"), .image)
        let found = await makeResolver(http).artwork(for: makeTitle("PCSF00243", "Killzone™: Mercenary"))
        #expect(found?.absoluteString == storeImage(killzone, "GB"))
        #expect(http.log == [
            "GET \(storeSearch("Killzone%3A%20Mercenary", "GB"))",
            "GET \(storeSearch("Killzone", "GB"))",
            "HEAD \(storeImage(killzone, "GB"))",
        ])
    }

    @Test func searchMakesAtMostThreeRequests() async {
        _ = await makeResolver(http).artwork(for: makeTitle("PCSE00001", "Alpha: Beta - Gamma: Delta - Epsilon"))
        #expect(http.log.filter { $0.hasPrefix("GET \(storeAPI)/tumbler/") } == [
            "GET \(storeSearch("Alpha%3A%20Beta%20-%20Gamma%3A%20Delta%20-%20Epsilon"))",
            "GET \(storeSearch("Alpha%3A%20Beta"))",
            "GET \(storeSearch("Alpha"))",
        ])
    }

    @Test func searchStopsWhenTheStoreCannotBeReached() async {
        http.on(.get, storeSearch("Grand%20Theft%20Auto%3A%20Liberty%20City%20Stories"), .failure(.timedOut))
        _ = await makeResolver(http).artwork(for: liberty)
        #expect(http.log.filter { $0.contains("/tumbler/") }.count == 1)
        #expect(http.log.contains("HEAD \(hexFlowCover("PSP", "ULUS10041"))"))
    }

    @Test(arguments: [FakeHTTPClient.Reply.status(503), .status(404), .json("<html>")])
    func searchTriesTheNextQueryAfterAnHTTPError(_ reply: FakeHTTPClient.Reply) async {
        let gta = "UP1004-ULUS10041_00-GTALIBERTYCITY00"
        http.on(.get, storeSearch("Grand%20Theft%20Auto%3A%20Liberty%20City%20Stories"), reply)
        http.on(.get, storeSearch("Grand%20Theft%20Auto"), .json(searchResponse([
            (gta, "Grand Theft Auto: Liberty City Stories", "downloadable_game"),
        ])))
        http.on(.head, storeImage(gta), .image)
        let found = await makeResolver(http).artwork(for: liberty)
        #expect(found?.absoluteString == storeImage(gta))
    }

    @Test func searchStopsAtTheFirstQueryThatFindsTheTitle() async {
        // The product is listed but its image is gone; a shorter query would only find it again.
        let gta = "UP1004-ULUS10041_00-GPCGRANDTH000001"
        http.on(.get, storeSearch("Grand%20Theft%20Auto%3A%20Liberty%20City%20Stories"), .json(searchResponse([
            (gta, "Grand Theft Auto: Liberty City Stories", "downloadable_game"),
        ])))
        http.on(.head, hexFlowCover("PSP", "ULUS10041"), .image)
        let found = await makeResolver(http).artwork(for: liberty)
        #expect(found?.absoluteString == hexFlowCover("PSP", "ULUS10041"))
        #expect(http.log == [
            "GET \(storeSearch("Grand%20Theft%20Auto%3A%20Liberty%20City%20Stories"))",
            "HEAD \(storeImage(gta))",
            "GET \(catalogURL)",
            "HEAD \(hexFlowCover("PSP", "ULUS10041"))",
        ])
    }

    @Test func searchTriesEachProductOfTheTitleInOrder() async {
        let first = "UP9000-PCSA00011_00-PDUSAP0000000001"
        let second = "UP9000-PCSA00011_00-PDUSAP1648614961"
        http.on(.get, storeSearch("Gravity%20Rush"), .json(searchResponse([
            (first, "Gravity Rush™", "downloadable_game"),
            (first, "Gravity Rush™", "downloadable_game"),
            (second, "Gravity Rush™", "downloadable_game"),
        ])))
        http.on(.head, storeImage(second), .image)
        let found = await makeResolver(http).artwork(for: makeTitle("PCSA00011", "Gravity Rush"))
        #expect(found?.absoluteString == storeImage(second))
        #expect(http.count(.head, storeImage(first)) == 1)
    }

    @Test(arguments: ["", "PCSE00120", "pcse00120"])
    func searchNeedsAName(_ name: String) async {
        _ = await makeResolver(http).artwork(for: makeTitle("PCSE00120", name))
        #expect(!http.log.contains { $0.contains("/tumbler/") })
    }

    @Test func searchSkipsTheContentIDsImageItAlreadyProbed() async {
        http.on(.get, storeSearch("Persona%204%20Golden"), .json(searchResponse([
            (personaUSStoreID, "Persona®4 Golden™", "downloadable_game"),
        ])))
        let persona = makeTitle("PCSE00120", "Persona 4 Golden", contentID: personaUSStoreID)
        _ = await makeResolver(http).artwork(for: persona)
        #expect(http.count(.head, storeImage(personaUSStoreID)) == 1)
    }

    // MARK: HexFlow

    @Test(arguments: [
        ("PCSE00120", "Persona 4 Golden", "PSVita"),
        ("ULUS10041", "Grand Theft Auto: Liberty City Stories", "PSP"),
        ("NPJH50465", "Project DIVA extend", "PSP"),
        ("SLUS00594", "Metal Gear Solid", "PS1"),
        ("SCES00344", "Crash Bandicoot", "PS1"),
        ("HOMEBREW1", "Some Homebrew", "PSVita"),
    ])
    func hexFlowCoverByKind(titleID: String, name: String, folder: String) async {
        http.on(.get, catalogURL, .json(standardCatalog))
        http.on(.head, hexFlowCover(folder, titleID), .image)
        let found = await makeResolver(http).artwork(for: makeTitle(titleID, name))
        #expect(found?.absoluteString == hexFlowCover(folder, titleID))
    }

    @Test func ps1GamesAreNotSearched() async {
        http.on(.head, hexFlowCover("PS1", "SLUS00594"), .image)
        #expect(await makeResolver(http).artwork(for: metalGear)?.absoluteString == hexFlowCover("PS1", "SLUS00594"))
        #expect(http.log == ["GET \(catalogURL)", "HEAD \(hexFlowCover("PS1", "SLUS00594"))"])
    }

    @Test func vitaGameOrder() async {
        let contentID = "UP0082-PCSE00120_00-PERSONA4GOLDEN01"
        http.on(.get, catalogURL, .json(standardCatalog))
        _ = await makeResolver(http).artwork(for: makeTitle("PCSE00120", "Persona 4 Golden", contentID: contentID))
        #expect(http.log == [
            "HEAD \(storeImage(contentID))",
            "GET \(storeSearch("Persona%204%20Golden"))",
            "GET \(catalogURL)",
            "HEAD \(hexFlowCover("PSVita", "PCSE00120"))",
        ])
    }

    @Test func pspGameOrder() async {
        http.on(.get, catalogURL, .json(standardCatalog))
        _ = await makeResolver(http).artwork(for: makeTitle("UCUS98711", "Patapon"))
        #expect(http.log == [
            "GET \(storeSearch("Patapon"))",
            "GET \(catalogURL)",
            "HEAD \(hexFlowCover("PSP", "UCUS98711"))",
        ])
    }

    // MARK: NeoVitaDB

    @Test func homebrewPrefersItsCatalogIconToHexFlow() async {
        http.on(.get, catalogURL, .json(standardCatalog))
        http.on(.head, catalogIcon("0021-vitashell.png"), .image)
        http.on(.head, hexFlowCover("PSVita", "VITASHELL"), .image)
        let found = await makeResolver(http).artwork(for: vitaShell)
        #expect(found?.absoluteString == catalogIcon("0021-vitashell.png"))
        #expect(http.log == ["GET \(catalogURL)", "HEAD \(catalogIcon("0021-vitashell.png"))"])
    }

    @Test func homebrewWithAContentIDTriesTheStoreFirst() async {
        let contentID = "IV0000-VITASHELL_00-0000000000000000"
        http.on(.get, catalogURL, .json(standardCatalog))
        http.on(.head, catalogIcon("0021-vitashell.png"), .image)
        let found = await makeResolver(http).artwork(for: makeTitle("VITASHELL", "VitaShell", contentID: contentID))
        #expect(found?.absoluteString == catalogIcon("0021-vitashell.png"))
        #expect(http.log == [
            "HEAD \(storeImage(contentID))",
            "GET \(catalogURL)",
            "HEAD \(catalogIcon("0021-vitashell.png"))",
        ])
    }

    @Test func homebrewIsNeverSearchedInTheStore() async {
        http.on(.get, catalogURL, .json(standardCatalog))
        _ = await makeResolver(http).artwork(for: makeTitle("MYHOMEBRW", "My Homebrew"))
        #expect(http.log == ["GET \(catalogURL)", "HEAD \(hexFlowCover("PSVita", "MYHOMEBRW"))"])
    }

    @Test func homebrewFallsBackToHexFlowWhenTheCatalogDoesNotListIt() async {
        http.on(.get, catalogURL, .json(standardCatalog))
        http.on(.head, hexFlowCover("PSVita", "ABCD99999"), .image)
        let found = await makeResolver(http).artwork(for: makeTitle("ABCD99999", "Unlisted"))
        #expect(found?.absoluteString == hexFlowCover("PSVita", "ABCD99999"))
    }

    @Test func homebrewFallsBackToHexFlowWhenTheIconIsGone() async {
        http.on(.get, catalogURL, .json(standardCatalog))
        http.on(.head, hexFlowCover("PSVita", "VITASHELL"), .image)
        let found = await makeResolver(http).artwork(for: vitaShell)
        #expect(found?.absoluteString == hexFlowCover("PSVita", "VITASHELL"))
        #expect(http.count(.head, catalogIcon("0021-vitashell.png")) == 1)
    }

    @Test func aTitleIDsOnlyCatalogEntryNeedsNoNameMatch() async {
        http.on(.get, catalogURL, .json(standardCatalog))
        http.on(.head, catalogIcon("1534-retroarch.png"), .image)
        let found = await makeResolver(http).artwork(for: makeTitle("RETROVITA", "RetroArch Nightly Build"))
        #expect(found?.absoluteString == catalogIcon("1534-retroarch.png"))
    }

    @Test(arguments: [
        ("Flappy Bird Vita", "1666-flappy-bird-vita.png"),
        ("FLAPPY BIRD", "1666-flappy-bird-vita.png"),
        ("V-Cube", "1673-v-cube.png"),
        ("Something Else Entirely", nil),
    ])
    func aSharedTitleIDNeedsAMatchingName(name: String, icon: String?) async {
        http.on(.get, catalogURL, .json(catalogBody([
            ("ABCD12345", "The Enchanted Forest", "1617-the-enchanted-forest.png"),
            ("ABCD12345", "Flappy Bird Vita", "1666-flappy-bird-vita.png"),
            ("ABCD12345", "V-Cube", "1673-v-cube.png"),
        ])))
        for file in ["1617-the-enchanted-forest.png", "1666-flappy-bird-vita.png", "1673-v-cube.png"] {
            http.on(.head, catalogIcon(file), .image)
        }
        let found = await makeResolver(http).artwork(for: makeTitle("ABCD12345", name))
        #expect(found?.absoluteString == icon.map(catalogIcon))
    }

    @Test func retailLookingIDGetsTheCatalogIconOnlyAsALastResort() async {
        http.on(.get, catalogURL, .json(standardCatalog))
        http.on(.head, catalogIcon("1520-history-deleter.png"), .image)
        let found = await makeResolver(http).artwork(for: makeTitle("PCSF00092", "History Deleter"))
        #expect(found?.absoluteString == catalogIcon("1520-history-deleter.png"))
        #expect(http.log == [
            "GET \(storeSearch("History%20Deleter", "GB"))",
            "GET \(catalogURL)",
            "HEAD \(catalogIcon("1520-history-deleter.png"))",
        ])
    }

    @Test func retailLookingIDPrefersANamedCatalogIconToHexFlow() async {
        http.on(.get, catalogURL, .json(standardCatalog))
        http.on(.head, catalogIcon("1520-history-deleter.png"), .image)
        http.on(.head, hexFlowCover("PSVita", "PCSF00092"), .image)
        let found = await makeResolver(http).artwork(for: makeTitle("PCSF00092", "History Deleter"))
        #expect(found?.absoluteString == catalogIcon("1520-history-deleter.png"))
        #expect(!http.log.contains("HEAD \(hexFlowCover("PSVita", "PCSF00092"))"))
    }

    @Test func retailLookingIDNeedsTheCatalogEntrysName() async {
        http.on(.get, catalogURL, .json(standardCatalog))
        http.on(.head, catalogIcon("1520-history-deleter.png"), .image)
        #expect(await makeResolver(http).artwork(for: makeTitle("PCSF00092", "Ecolibrium")) == nil)
        #expect(!http.log.contains("HEAD \(catalogIcon("1520-history-deleter.png"))"))
    }

    @Test func adrenalineMenuShowsTheAdrenalineIcon() async {
        http.on(.get, catalogURL, .json(standardCatalog))
        http.on(.head, catalogIcon("0047-adrenaline.png"), .image)
        let found = await makeResolver(http).artwork(for: adrenalineMenu)
        #expect(found?.absoluteString == catalogIcon("0047-adrenaline.png"))
        #expect(http.log == ["GET \(catalogURL)", "HEAD \(catalogIcon("0047-adrenaline.png"))"])
    }

    @Test func adrenalineMenuPrefersTheEntryNamedAdrenaline() async {
        http.on(.get, catalogURL, .json(catalogBody([
            ("PSPEMUCFW", "Adrenaline Bubble Manager", "0100-abm.png"),
            ("PSPEMUCFW", "Adrenaline", "0047-adrenaline.png"),
        ])))
        http.on(.head, catalogIcon("0100-abm.png"), .image)
        http.on(.head, catalogIcon("0047-adrenaline.png"), .image)
        let found = await makeResolver(http).artwork(for: makeTitle("xmb", ""))
        #expect(found?.absoluteString == catalogIcon("0047-adrenaline.png"))
    }

    @Test func adrenalineMenuHasNoOtherSource() async {
        http.on(.get, catalogURL, .json(catalogBody([])))
        #expect(await makeResolver(http).artwork(for: adrenalineMenu) == nil)
        #expect(http.log == ["GET \(catalogURL)"])
    }

    // MARK: Probing and URL rules

    @Test(arguments: [
        FakeHTTPClient.Reply.status(404),
        .status(410),
        .status(200, headers: ["content-type": "text/html; charset=utf-8"]),
        .status(200),
        .status(302, headers: ["location": "https://example.com/image.png"]),
        .status(302, headers: ["location": "https://example.com/image.png", "content-type": "image/png"]),
        .status(204, headers: ["content-type": "image/png"]),
        .status(500, headers: ["content-type": "image/png"]),
        .offline,
    ])
    func probeAcceptsOnly200WithAnImageType(_ reply: FakeHTTPClient.Reply) async {
        http.on(.head, hexFlowCover("PS1", "SLUS00594"), reply)
        #expect(await makeResolver(http).artwork(for: metalGear) == nil)
        #expect(http.count(.head, hexFlowCover("PS1", "SLUS00594")) == 1)
    }

    @Test(arguments: ["image/png", "image/jpeg;charset=UTF-8", "IMAGE/WEBP", " image/gif ; q=1"])
    func probeAcceptsAnyImageType(_ type: String) async {
        http.on(.head, hexFlowCover("PS1", "SLUS00594"), .status(200, headers: ["content-type": type]))
        #expect(await makeResolver(http).artwork(for: metalGear)?.absoluteString == hexFlowCover("PS1", "SLUS00594"))
    }

    @Test(arguments: [
        "my icon.png",
        "icon.png?v=2",
        "icon.png#top",
        "../secret.png",
        ".hidden.png",
        "sub/dir.png",
        "ikona-\u{0105}.png",
        String(repeating: "a", count: 210) + ".png",
    ])
    func iconsWithUnusableURLsAreNeverProbed(_ icon: String) async {
        let body = #"[{"name":"Odd","icon":"\#(icon)","titleid":"ODDICON01"}]"#
        http.on(.get, catalogURL, .json(body))
        #expect(await makeResolver(http).artwork(for: makeTitle("ODDICON01", "Odd")) == nil)
        #expect(http.log == ["GET \(catalogURL)", "HEAD \(hexFlowCover("PSVita", "ODDICON01"))"])
    }

    @Test(arguments: ["BAD ID", "PCSE00120/../x", "HOMEBREW?", "ÜBER0001"])
    func titleIDsThatArentPlainNeverBecomeURLs(_ titleID: String) async {
        http.on(.get, catalogURL, .json(standardCatalog))
        #expect(await makeResolver(http).artwork(for: makeTitle(titleID, "")) == nil)
        #expect(http.log == ["GET \(catalogURL)"])
    }

    @Test func everyHandedOutURLFollowsTheRules() async throws {
        http.on(.get, storeSearch("Persona%204%20Golden"), .json(searchResponse([
            (personaUSStoreID, "Persona®4 Golden™", "downloadable_game"),
        ])))
        http.on(.get, catalogURL, .json(standardCatalog))
        for url in [storeImage(personaUSStoreID), catalogIcon("0021-vitashell.png"), hexFlowCover("PS1", "SLUS00594")] {
            http.on(.head, url, .image)
        }
        let resolver = makeResolver(http)
        for title in [personaUS, vitaShell, metalGear] {
            let url = try #require(await resolver.artwork(for: title))
            let text = url.absoluteString
            #expect(text.hasPrefix("https://"))
            #expect(text.count <= 256)
            #expect(url.query == nil)
            #expect(!text.contains(" "))
        }
    }
}

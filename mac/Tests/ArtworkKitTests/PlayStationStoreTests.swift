import Foundation
import Testing
@testable import ArtworkKit

private typealias Storefront = PlayStationStore.Storefront

struct PlayStationStoreTests {
    // MARK: Storefronts

    @Test(arguments: [
        ("UP0005-PCSE00120_00-PERSONA4GOLDEN01", "US", "en"),
        ("EP1063-PCSB00245_00-PERSONA4GOLDEN01", "GB", "en"),
        ("JP0005-PCSG00563_00-PERSONA4GOLDEN01", "JP", "ja"),
        ("HP9000-PCSD00003_00-PDHKAP1633013602", "SG", "en"),
        ("KP0001-PCSH00021_00-KOREANEDITION000", "KR", "ko"),
        ("ep1063-pcsb00245_00-persona4golden01", "GB", "en"),
        ("IP0000-PCSE00001_00-0000000000000000", "US", "en"),
        ("AP0000-PCSE00001_00-0000000000000000", "US", "en"),
        ("", "US", "en"),
    ])
    func storefrontOfAContentID(contentID: String, country: String, language: String) {
        #expect(Storefront(contentID: contentID) == Storefront(country: country, language: language))
    }

    @Test(arguments: [
        ("PCSA00011", "US"), ("PCSE00120", "US"), ("PCSB00245", "GB"), ("PCSF00243", "GB"),
        ("PCSC00045", "JP"), ("PCSG00004", "JP"), ("PCSD00003", "SG"), ("PCSH10001", "SG"),
        ("pcsb00245", "GB"), ("PCSI00001", "US"),
        ("ULUS10041", "US"), ("UCUS98711", "US"), ("NPUH10091", "US"), ("NPUG80318", "US"),
        ("ULES01213", "GB"), ("UCES00001", "GB"), ("NPEZ00001", "GB"), ("NPEH00020", "GB"),
        ("ULJM05800", "JP"), ("ULJS00001", "JP"), ("UCJS10041", "JP"), ("NPJH50465", "JP"),
        ("ULAS42019", "SG"), ("UCAS40001", "SG"), ("NPHH00123", "SG"),
        ("ULKS46164", "KR"), ("UCKS45001", "KR"), ("NPKH00001", "KR"),
        ("", "US"), ("XMB", "US"),
    ])
    func storefrontOfATitleID(titleID: String, country: String) {
        let language = ["US": "en", "GB": "en", "JP": "ja", "SG": "en", "KR": "ko"][country]!
        #expect(Storefront(titleID: titleID) == Storefront(country: country, language: language))
    }

    // MARK: Content IDs and URLs

    @Test(arguments: [
        "UP0005-PCSE00120_00-PERSONA4GOLDEN01",
        "EP9000-PCSF00243_00-KZV0000000000000",
        "up0005-pcse00120_00-persona4golden01",
        "XX0000-HOMEBREW1_AB-0000000000000000",
    ])
    func contentIDShapeIsAccepted(_ text: String) {
        #expect(PlayStationStore.isContentID(text))
    }

    @Test(arguments: [
        "",
        "UP0005-PCSE00120_00-PERSONA4GOLDEN0",
        "UP0005-PCSE00120_00-PERSONA4GOLDEN012",
        "UP0005_PCSE00120_00-PERSONA4GOLDEN01",
        "UP0005-PCSE00120-00-PERSONA4GOLDEN01",
        "UP0005-PCSE00120_00_PERSONA4GOLDEN01",
        "UP0005-PCSE00120_00-PERSONA4 GOLDEN1",
        "UP0005-PCSE00120_00-PERSONA4GOLDEN/1",
        "ÜP0005-PCSE00120_00-PERSONA4GOLDEN01",
        "UP0005-PCSE00120_00-PERSONA4GOLDEN01\n",
    ])
    func otherTextIsNotAContentID(_ text: String) {
        #expect(!PlayStationStore.isContentID(text))
    }

    @Test func imageURL() {
        let url = PlayStationStore.imageURL(contentID: "EP1063-PCSB00245_00-PERSONA4GOLDEN01", in: .unitedKingdom)
        #expect(url?.absoluteString == """
            https://store.playstation.com/store/api/chihiro/00_09_000/container/GB/en/19/\
            EP1063-PCSB00245_00-PERSONA4GOLDEN01/1534563384000/image
            """)
        #expect(url.map(ArtworkURL.isAcceptable) == true)
        #expect(PlayStationStore.imageURL(contentID: "../../evil", in: .unitedStates) == nil)
    }

    @Test(arguments: [
        ("Persona 4 Golden", "Persona%204%20Golden"),
        ("Killzone: Mercenary", "Killzone%3A%20Mercenary"),
        ("Tom & Jerry's #1 / 100%?", "Tom%20%26%20Jerry%27s%20%231%20100%25%3F"),
        ("ペルソナ4", "%E3%83%9A%E3%83%AB%E3%82%BD%E3%83%8A4"),
        ("A-b.c_d~e", "A-b.c_d~e"),
    ])
    func searchURLEncodesTheQueryAsOnePathSegment(query: String, encoded: String) {
        #expect(PlayStationStore.searchURL(for: query, in: .japan)?.absoluteString == """
            https://store.playstation.com/store/api/chihiro/00_09_000/tumbler/JP/ja/999/\(encoded)\
            ?suggested_size=10&mode=game
            """)
    }

    // MARK: Queries

    @Test(arguments: [
        ("Persona 4 Golden", "Persona 4 Golden"),
        ("Persona®4 Golden™", "Persona 4 Golden"),
        ("Uncharted™: Golden Abyss™", "Uncharted: Golden Abyss"),
        ("Minecraft: PlayStation®Vita Edition", "Minecraft"),
        ("Minecraft PlayStation®Vita Edition", "Minecraft"),
        ("MINECRAFT: PLAYSTATION VITA EDITION", "MINECRAFT"),
        ("  Tearaway  ©  2013 ", "Tearaway 2013"),
        ("Gravity\tRush\n", "Gravity Rush"),
        ("Edition PlayStation Vita", "Edition PlayStation Vita"),
        ("™®©", ""),
    ])
    func cleanedName(name: String, cleaned: String) {
        #expect(PlayStationStore.cleanedName(name) == cleaned)
    }

    @Test(arguments: [
        ("Persona 4 Golden", ["Persona 4 Golden"]),
        ("Grand Theft Auto: Liberty City Stories", ["Grand Theft Auto: Liberty City Stories", "Grand Theft Auto"]),
        ("Killzone™: Mercenary", ["Killzone: Mercenary", "Killzone"]),
        ("Ys - Memories of Celceta", ["Ys - Memories of Celceta", "Ys"]),
        ("Hatsune Miku: Project DIVA f - Deluxe", [
            "Hatsune Miku: Project DIVA f - Deluxe", "Hatsune Miku: Project DIVA f", "Hatsune Miku",
        ]),
        ("Alpha - Beta: Gamma", ["Alpha - Beta: Gamma", "Alpha - Beta", "Alpha"]),
        ("Minecraft: PlayStation®Vita Edition", ["Minecraft"]),
        ("ペルソナ4 ザ・ゴールデン", ["ペルソナ4 ザ・ゴールデン"]),
        ("テイルズ オブ イノセンス：R", ["テイルズ オブ イノセンス：R", "テイルズ オブ イノセンス"]),
        ("Spider-Man", ["Spider-Man"]),
        (": Nothing Before", [": Nothing Before"]),
        ("", []),
    ])
    func searchQueriesGetShorter(name: String, queries: [String]) {
        #expect(PlayStationStore.searchQueries(for: name) == queries)
    }

    // MARK: Search results

    @Test func productsKeepsOnlyTheExactTitleIDInOrder() throws {
        let body = searchResponse([
            ("UP9000-CUSA03694_00-GRAVITYRUSH20000", "Gravity Rush 2", "downloadable_game"),
            ("UP9000-PCSA00011_00-PDUSAP1648614961", "Gravity Rush", "downloadable_game"),
            ("UP9000-PCSA00011_00-PDUSAP1648614961", "Gravity Rush", "downloadable_game"),
            ("UP9000-PCSA00011_00-PDUSAC00MAIDPACK", "Gravity Rush Maid Costume Pack", "add_on"),
            ("UP9000-PCSA00011_00-PDUSAPDISCONLY00", "Gravity Rush", "disc_based_game"),
            ("UP9000-PCSA000110_0-PDUSAP1648614961", "Gravity Rush", "downloadable_game"),
            ("UP9000-PCSA00012_00-PDUSAP1648614961", "Gravity Rush", "downloadable_game"),
            ("up9000-pcsa00011_00-lowercase0000000", "Gravity Rush", "downloadable_game"),
        ])
        #expect(try PlayStationStore.products(in: Data(body.utf8), matching: "PCSA00011") == [
            "UP9000-PCSA00011_00-PDUSAP1648614961",
            "UP9000-PCSA00011_00-PDUSAPDISCONLY00",
            "UP9000-PCSA00011_00-LOWERCASE0000000",
        ])
    }

    @Test func productsToleratesOddEntries() throws {
        let body = """
            {"links":[null,7,{"name":"No ID"},{"id":12},{"id":"UP0005-PCSE00120_00-PERSONA4GOLDEN01","top_category":5},
            {"id":"UP0005-PCSE00120_00-PERSONA4GOLDEN02"}]}
            """
        #expect(try PlayStationStore.products(in: Data(body.utf8), matching: "PCSE00120") == [
            "UP0005-PCSE00120_00-PERSONA4GOLDEN01",
            "UP0005-PCSE00120_00-PERSONA4GOLDEN02",
        ])
    }

    @Test(arguments: [#"{"size":0}"#, #"{"links":[]}"#, #"{"links":null}"#])
    func anEmptySearchHasNoProducts(_ body: String) throws {
        #expect(try PlayStationStore.products(in: Data(body.utf8), matching: "PCSE00120").isEmpty)
    }

    @Test(arguments: ["", "<html>", "[]", #"{"links":{}}"#, #"{"links":"x"}"#])
    func aBodyThatIsNotASearchResponseThrows(_ body: String) {
        #expect(throws: (any Error).self) { try PlayStationStore.products(in: Data(body.utf8), matching: "PCSE00120") }
    }

    @Test func realSearchResponseParses() throws {
        // Shape of a real tumbler response (trimmed): P4G US among PS4 and PS5 products.
        let body = """
            {"age_limit":0,"attributes":{"facets":{},"next":[]},"links":[
            {"bucket":"games","container_type":"product","id":"UP0177-CUSA33873_00-DAYLIGHT00000000",
            "name":"Persona 4 Golden","playable_platform":["PS4™"],"top_category":"downloadable_game",
            "images":[{"type":10,"url":"https://image.api.playstation.com/x.png"}]},
            {"bucket":"games","container_type":"product","id":"UP0005-PCSE00120_00-PERSONA4GOLDEN01",
            "name":"Persona®4 Golden™ ","playable_platform":["PS Vita"],"top_category":"downloadable_game",
            "images":[{"type":1,"url":"https://apollo2.dl.playstation.net/cdn/UP0005/PCSE00120_00/x.png"}],
            "default_sku":{"display_price":"$19.99","price":1999}}],
            "size":2,"start":0,"total_results":2}
            """
        #expect(try PlayStationStore.products(in: Data(body.utf8), matching: "PCSE00120") == [
            "UP0005-PCSE00120_00-PERSONA4GOLDEN01",
        ])
    }
}

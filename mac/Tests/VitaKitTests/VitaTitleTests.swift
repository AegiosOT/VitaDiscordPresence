import Foundation
import Testing
@testable import VitaKit

struct VitaTitleKindTests {
    private func kind(of titleID: String, index: Int32 = 1) -> VitaTitle.Kind {
        VitaTitle(index: index, titleID: titleID, name: "Name").kind
    }

    @Test func liveArea() {
        #expect(VitaTitle.liveArea.kind == .liveArea)
        // Index 0 wins, whatever the fields say.
        #expect(kind(of: "PCSE00120", index: 0) == .liveArea)
        #expect(kind(of: "XMB", index: 0) == .liveArea)
    }

    @Test(arguments: ["NPXS10015", "NPXS10000", "NPXS10003", "NPXS10026"])
    func systemApps(titleID: String) {
        #expect(kind(of: titleID) == .systemApp)
    }

    @Test func adrenalineMenu() {
        #expect(kind(of: "XMB") == .adrenalineMenu)
        #expect(kind(of: "XMB", index: 20) == .adrenalineMenu)
    }

    @Test(arguments: [
        "PCSA00011", "PCSB00245", "PCSC00001", "PCSD00010", "PCSE00120", "PCSF00011", "PCSG00563", "PCSH00021",
    ])
    func retailVitaGames(titleID: String) {
        #expect(kind(of: titleID) == .vitaGame)
    }

    @Test(arguments: [
        "ULUS10041", "UCUS98711", "ULES01213", "UCES01245", "ULJM05500", "ULJS00019", "UCJS10041", "ULAS42095",
        "UCAS40266", "ULKS46033", "NPUH10091", "NPUG80320", "NPEH00020", "NPEG00001", "NPEZ00226", "NPUZ00001",
        "NPJH50465", "NPJG00010", "NPHG00035",
    ])
    func pspGames(titleID: String) {
        #expect(kind(of: titleID) == .pspGame)
    }

    @Test(arguments: ["SLUS00594", "SCUS94163", "SLES02080", "SCES00344", "SLPM86023", "SLPS01541", "SCPS10031"])
    func ps1Games(titleID: String) {
        #expect(kind(of: titleID) == .ps1Game)
    }

    @Test(arguments: ["VITASHELL", "PSPEMUCFW", "VSDK00001", "RETROVITA", "MLCL00001", "PKGJ00000", "SKGLEAVE1"])
    func homebrewIsOther(titleID: String) {
        #expect(kind(of: titleID) == .other)
    }

    @Test(arguments: [
        "",  // an app with an empty title ID still isn't the LiveArea
        "PCSE0012", "PCSE001200", "PCSE0012A", "PCS100120", "PCSE 0120", "PCSE00120 ", "PCSE0012٣", "ＰＣＳＥ００１２０",
        "PCSI00001", "PCSZ99999",  // past PCSH
        "NPXS1001", "NPXS100150", "NPX10015",
        "XMB1", "XM",
        "ULUS1004", "ULUS100410", "U1US10041", "NPJH5046", "NP1H50465",
        "SLUS0059", "SLUS005940", "S1US00594",
        "SABC12345", "UAAA12345",  // serial-shaped, but not a Sony region letter
    ])
    func malformedIDsAreOther(titleID: String) {
        #expect(kind(of: titleID) == .other)
    }

    @Test func ignoresLetterCase() {
        #expect(kind(of: "pcse00120") == .vitaGame)
        #expect(kind(of: "npxs10015") == .systemApp)
        #expect(kind(of: "xmb") == .adrenalineMenu)
        #expect(kind(of: "ulus10041") == .pspGame)
        #expect(kind(of: "slus00594") == .ps1Game)
    }
}

struct VitaTitleTests {
    @Test func hasNoContentIDUnlessGivenOne() {
        #expect(VitaTitle(index: 1, titleID: "PCSE00120", name: "Persona 4 Golden").contentID == nil)
        #expect(VitaTitle.liveArea.contentID == nil)
    }

    @Test func codableKeepsTheContentID() throws {
        let titles = [
            VitaTitle(index: 1, titleID: "PCSE00120", name: "P4G", contentID: "UP0005-PCSE00120_00-PERSONA4GOLDEN01"),
            VitaTitle(index: 2, titleID: "VITASHELL", name: "VitaShell"),
        ]
        let decoded = try JSONDecoder().decode([VitaTitle].self, from: JSONEncoder().encode(titles))
        #expect(decoded == titles)
    }

    @Test func decodesTitlesEncodedWithoutAContentID() throws {
        let json = Data(#"{"index":3,"titleID":"PCSE00120","name":"Persona 4 Golden"}"#.utf8)
        let title = try JSONDecoder().decode(VitaTitle.self, from: json)
        #expect(title == VitaTitle(index: 3, titleID: "PCSE00120", name: "Persona 4 Golden"))
    }
}

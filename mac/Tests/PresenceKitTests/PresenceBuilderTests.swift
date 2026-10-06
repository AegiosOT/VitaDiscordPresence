import DiscordIPC
import Foundation
import Testing
import VitaKit
@testable import PresenceKit

@Suite struct PresenceBuilderTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000.25)
    private let art = URL(string: "https://raw.githubusercontent.com/Andiweli/HexFlow-Covers/main/Covers/PSVita/"
        + "PCSE00120.png")!

    private func activity(
        _ title: VitaTitle = persona,
        _ settings: PresenceSettings = PresenceSettings(),
        sessionStart: Date? = nil,
        artwork: URL? = nil
    ) -> DiscordActivity? {
        PresenceBuilder.activity(for: title, settings: settings, sessionStart: sessionStart, artwork: artwork)
    }

    // MARK: Title and details

    @Test func theGameIsTheTitleAndThePlatformTheDetails() {
        #expect(activity(persona) == DiscordActivity(type: 0, name: "Persona 4 Golden", details: "PlayStation Vita"))
    }

    @Test(arguments: [
        (VitaTitle(index: 1, titleID: "PCSE00120", name: "Persona 4 Golden"), "PlayStation Vita"),
        (VitaTitle(index: 1, titleID: "UCUS98711", name: "Patapon"), "PSP on PlayStation Vita"),
        (VitaTitle(index: 1, titleID: "NPJH50465", name: "A PSP Game From PSN"), "PSP on PlayStation Vita"),
        (VitaTitle(index: 1, titleID: "SCUS94163", name: "Final Fantasy VII"), "PS1 on PlayStation Vita"),
        (VitaTitle(index: 1, titleID: "NPXS10015", name: "Settings"), "PlayStation Vita"),
        (VitaTitle(index: 1, titleID: "VITASHELL", name: "VitaShell"), "PlayStation Vita"),
    ])
    func detailsNameThePlatform(title: VitaTitle, platform: String) {
        let result = activity(title)
        #expect(result?.type == 0)
        #expect(result?.name == title.name)
        #expect(result?.details == platform)
    }

    @Test func adrenalinesMenuIsNamedAdrenaline() {
        let menu = VitaTitle(index: 2, titleID: "XMB", name: "Adrenaline XMB Menu")
        #expect(activity(menu) == DiscordActivity(type: 0, name: "Adrenaline", details: "PlayStation Vita"))
    }

    @Test func nameFallsBackToTheTitleID() {
        let unnamed = VitaTitle(index: 2, titleID: "VITASHELL", name: "")
        #expect(activity(unnamed)?.name == "VITASHELL")
    }

    // MARK: LiveArea

    @Test func liveAreaIsShownWhenEnabled() {
        let result = activity(.liveArea, PresenceSettings(showLiveArea: true))
        #expect(result == DiscordActivity(
            type: 0,
            name: "PlayStation Vita",
            details: "In the LiveArea",
            assets: DiscordActivity.Assets(largeImage: PresenceBuilder.liveAreaImage, largeText: "PlayStation Vita")
        ))
    }

    @Test func liveAreaClearsThePresenceWhenDisabled() {
        #expect(activity(.liveArea, PresenceSettings(showLiveArea: false), sessionStart: start) == nil)
        #expect(activity(persona, PresenceSettings(showLiveArea: false))?.name == persona.name)
    }

    @Test func liveAreaShowsOnlyACustomImage() {
        // A looked-up cover is ignored. The LiveArea uses its own icon unless artwork is turned off.
        #expect(activity(.liveArea, artwork: art)?.assets?.largeImage == PresenceBuilder.liveAreaImage)
        #expect(activity(.liveArea, PresenceSettings(showGameArtwork: false))?.assets == nil)
        let custom = activity(.liveArea, PresenceSettings(largeImageKey: "vita"), artwork: art)
        #expect(custom?.assets == DiscordActivity.Assets(largeImage: "vita", largeText: "PlayStation Vita"))
    }

    @Test func builtInAppsUseTheirOwnIcon() throws {
        let settings = VitaTitle(index: 1, titleID: "NPXS10015", name: "Settings")
        let icon = try #require(SystemAppIcons.image(for: "NPXS10015"))
        #expect(activity(settings)?.assets == DiscordActivity.Assets(
            largeImage: icon,
            largeText: "Settings (NPXS10015)"
        ))
        #expect(activity(settings, artwork: art)?.assets?.largeImage == icon)
        #expect(activity(settings, PresenceSettings(showGameArtwork: false))?.assets == nil)
        let custom = activity(settings, PresenceSettings(largeImageKey: "vita"))
        #expect(custom?.assets?.largeImage == "vita")

        let browser = VitaTitle(index: 1, titleID: "npxs10003", name: "Browser")
        #expect(activity(browser)?.assets?.largeImage == SystemAppIcons.image(for: "NPXS10003"))

        let internalApp = VitaTitle(index: 1, titleID: "NPXS10063", name: "MsgMW")
        #expect(activity(internalApp)?.assets == nil)
        #expect(SystemAppIcons.images.count == 22)
        for image in SystemAppIcons.images.values {
            #expect(DiscordActivity.acceptableImage(image) == image)
        }
    }

    @Test func liveAreaCarriesItsSessionStartToo() {
        let result = activity(.liveArea, PresenceSettings(), sessionStart: start)
        #expect(result?.timestamps?.start == 1_700_000_000_250)
    }

    // MARK: State and elapsed time

    @Test func stateIsTheCustomTextUnlessBlank() {
        #expect(activity(persona, PresenceSettings(stateText: "On my PS TV"))?.state == "On my PS TV")
        #expect(activity(persona, PresenceSettings(stateText: " \n\t "))?.state == nil)
        #expect(activity(persona, PresenceSettings(stateText: ""))?.state == nil)
    }

    @Test func elapsedTimeIsTheSessionStartInMilliseconds() {
        let result = activity(persona, PresenceSettings(showElapsedTime: true), sessionStart: start)
        #expect(result?.timestamps == DiscordActivity.Timestamps(start: 1_700_000_000_250))
    }

    @Test func elapsedTimeIsOmittedWhenOffOrUnknown() {
        #expect(activity(persona, PresenceSettings(showElapsedTime: false), sessionStart: start)?.timestamps == nil)
        #expect(activity(persona, PresenceSettings(showElapsedTime: true), sessionStart: nil)?.timestamps == nil)
    }

    // MARK: Large image

    @Test func artworkIsTheLargeImageWithNameAndTitleIDAsText() {
        let expected = DiscordActivity.Assets(largeImage: art.absoluteString, largeText: "Persona 4 Golden (PCSE00120)")
        #expect(activity(persona, artwork: art)?.assets == expected)
    }

    @Test func artworkIsLeftOutWhenTurnedOff() {
        #expect(activity(persona, PresenceSettings(showGameArtwork: false), artwork: art)?.assets == nil)
    }

    @Test func customImageReplacesTheArtwork() {
        let expected = DiscordActivity.Assets(largeImage: "vita", largeText: "Persona 4 Golden (PCSE00120)")
        #expect(activity(persona, PresenceSettings(largeImageKey: "vita"), artwork: art)?.assets == expected)
        #expect(activity(persona, PresenceSettings(largeImageKey: "vita"))?.assets == expected)
        let artworkOff = PresenceSettings(largeImageKey: "vita", showGameArtwork: false)
        #expect(activity(persona, artworkOff, artwork: art)?.assets == expected)
    }

    @Test func customImageCanBeAnImageURL() {
        let url = "https://example.com/vita.png"
        #expect(activity(persona, PresenceSettings(largeImageKey: url), artwork: art)?.assets?.largeImage == url)
    }

    @Test func anUnusableCustomImageFallsBackToTheArtwork() {
        let http = PresenceSettings(largeImageKey: "http://example.com/art.png")
        #expect(activity(persona, http, artwork: art)?.assets?.largeImage == art.absoluteString)
        let tooLong = "https://example.com/" + String(repeating: "a", count: 250)
        #expect(activity(persona, PresenceSettings(largeImageKey: tooLong), artwork: art)?.assets?.largeImage == art.absoluteString)
        #expect(http.largeImageWarning == "Use an https URL of at most 256 characters, with no spaces")
    }

    @Test func blankCustomImageFallsBackToTheArtwork() {
        let settings = PresenceSettings(largeImageKey: "  \n")
        #expect(activity(persona, settings, artwork: art)?.assets?.largeImage == art.absoluteString)
    }

    @Test func noImageMeansNoAssets() {
        #expect(activity(persona)?.assets == nil)
        #expect(activity(persona, PresenceSettings(largeImageKey: "   "))?.assets == nil)
        #expect(activity(persona, PresenceSettings(largeImageKey: ""))?.assets == nil)
    }

    @Test func artworkDiscordCantShowIsLeftOut() throws {
        let insecure = try #require(URL(string: "http://example.com/art.png"))
        #expect(activity(persona, artwork: insecure)?.assets == nil)
        let tooLong = try #require(URL(string: "https://example.com/" + String(repeating: "a", count: 240) + ".png"))
        #expect(activity(persona, artwork: tooLong)?.assets == nil)
    }

    @Test func largeTextOfOtherPlatforms() {
        let psp = VitaTitle(index: 1, titleID: "ULUS10041", name: "Grand Theft Auto: Liberty City Stories")
        #expect(activity(psp, artwork: art)?.assets?.largeText == "Grand Theft Auto: Liberty City Stories (ULUS10041)")
        let menu = VitaTitle(index: 2, titleID: "XMB", name: "Adrenaline XMB Menu")
        #expect(activity(menu, artwork: art)?.assets?.largeText == "Adrenaline (XMB)")
    }

    @Test func largeTextIsTheNameAloneWhenTheTitleIDAddsNothing() {
        let unnamed = VitaTitle(index: 2, titleID: "VITASHELL", name: "")
        #expect(activity(unnamed, artwork: art)?.assets?.largeText == "VITASHELL")
        let withoutTitleID = VitaTitle(index: 2, titleID: "", name: "Mystery")
        #expect(activity(withoutTitleID, artwork: art)?.assets?.largeText == "Mystery")
    }

    @Test func longNameIsShortenedSoTheTitleIDStillFits() throws {
        let title = VitaTitle(index: 1, titleID: "PCSE00001", name: String(repeating: "a", count: 200))
        let text = try #require(activity(title, artwork: art)?.assets?.largeText)
        #expect(text == String(repeating: "a", count: 115) + "… (PCSE00001)")
        #expect(text.utf16.count == 128)
    }

    // MARK: Everything and Discord's limits

    @Test func everythingTogether() {
        let settings = PresenceSettings(stateText: "Chilling", showElapsedTime: true)
        #expect(activity(persona, settings, sessionStart: start, artwork: art) == DiscordActivity(
            type: 0,
            name: "Persona 4 Golden",
            details: "PlayStation Vita",
            state: "Chilling",
            timestamps: DiscordActivity.Timestamps(start: 1_700_000_000_250),
            assets: DiscordActivity.Assets(largeImage: art.absoluteString, largeText: "Persona 4 Golden (PCSE00120)")
        ))
    }

    @Test func oneCharacterStringsArePaddedExceptTheName() {
        let padded = "X" + String(DiscordText.padding)
        let result = activity(
            VitaTitle(index: 1, titleID: "PCSE00001", name: "X"),
            PresenceSettings(stateText: "X", largeImageKey: "vita")
        )
        #expect(result?.name == "X", "a name may be a single character")
        #expect(result?.state == padded)
        #expect(result?.assets?.largeText == "X (PCSE00001)")
    }

    @Test func longStringsAreCutToDiscordsLimit() throws {
        let long = String(repeating: "a", count: 129)
        let cut = String(repeating: "a", count: 127) + "…"
        let result = try #require(activity(
            VitaTitle(index: 1, titleID: "PCSE00001", name: long),
            PresenceSettings(stateText: long, largeImageKey: "vita")
        ))
        #expect(result.name == cut)
        #expect(result.state == cut)
        #expect(result.name?.utf16.count == 128)
        #expect(result.assets?.largeText?.utf16.count == 128)
    }

    @Test func resultIsAlwaysSanitized() throws {
        let title = VitaTitle(index: 1, titleID: "PCSE00001", name: String(repeating: "😺", count: 100))
        let result = try #require(activity(title, PresenceSettings(stateText: "  x  "), artwork: art))
        #expect(result == result.sanitized())
        #expect(try #require(result.name).utf16.count <= 128)
        #expect(try #require(result.assets?.largeText).utf16.count <= 128)
    }
}

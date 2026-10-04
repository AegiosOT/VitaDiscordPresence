import DiscordIPC
import Foundation
import Testing
import VitaKit
@testable import PresenceKit

@Suite struct PresenceBuilderTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000.25)

    private func activity(
        _ title: VitaTitle = persona,
        _ settings: PresenceSettings = PresenceSettings(),
        sessionStart: Date? = nil
    ) -> DiscordActivity? {
        PresenceBuilder.activity(for: title, settings: settings, sessionStart: sessionStart)
    }

    @Test func liveAreaIsShownWhenEnabled() {
        let result = activity(.liveArea, PresenceSettings(showLiveArea: true))
        #expect(result == DiscordActivity(details: "In the LiveArea"))
    }

    @Test func liveAreaClearsThePresenceWhenDisabled() {
        #expect(activity(.liveArea, PresenceSettings(showLiveArea: false), sessionStart: start) == nil)
        #expect(activity(persona, PresenceSettings(showLiveArea: false))?.details == persona.name)
    }

    @Test func detailsAreTheGameName() {
        #expect(activity(persona) == DiscordActivity(details: "Persona 4 Golden"))
    }

    @Test func detailsFallBackToTheTitleID() {
        let unnamed = VitaTitle(index: 2, titleID: "VITASHELL", name: "")
        #expect(activity(unnamed)?.details == "VITASHELL")
    }

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

    @Test func liveAreaCarriesItsSessionStartToo() {
        let result = activity(.liveArea, PresenceSettings(), sessionStart: start)
        #expect(result?.timestamps?.start == 1_700_000_000_250)
    }

    @Test func imageKeyAddsAssetsWithTheNameAsLargeText() {
        let result = activity(persona, PresenceSettings(largeImageKey: "vita"))
        #expect(result?.assets == DiscordActivity.Assets(largeImage: "vita", largeText: "Persona 4 Golden"))
        let liveArea = activity(.liveArea, PresenceSettings(largeImageKey: "vita"))
        #expect(liveArea?.assets == DiscordActivity.Assets(largeImage: "vita", largeText: "LiveArea"))
    }

    @Test func blankImageKeyMeansNoAssets() {
        #expect(activity(persona, PresenceSettings(largeImageKey: "   "))?.assets == nil)
        #expect(activity(persona, PresenceSettings(largeImageKey: ""))?.assets == nil)
    }

    @Test func everythingTogether() {
        let settings = PresenceSettings(stateText: "Chilling", largeImageKey: "vita", showElapsedTime: true)
        #expect(activity(persona, settings, sessionStart: start) == DiscordActivity(
            details: "Persona 4 Golden",
            state: "Chilling",
            timestamps: DiscordActivity.Timestamps(start: 1_700_000_000_250),
            assets: DiscordActivity.Assets(largeImage: "vita", largeText: "Persona 4 Golden")
        ))
    }

    @Test func oneCharacterStringsArePadded() {
        let padded = "X" + String(DiscordText.padding)
        let result = activity(
            VitaTitle(index: 1, titleID: "PCSE00001", name: "X"),
            PresenceSettings(stateText: "X", largeImageKey: "vita")
        )
        #expect(result?.details == padded)
        #expect(result?.state == padded)
        #expect(result?.assets?.largeText == padded)
    }

    @Test func longStringsAreCutToDiscordsLimit() throws {
        let long = String(repeating: "a", count: 129)
        let cut = String(repeating: "a", count: 127) + "…"
        let result = try #require(activity(
            VitaTitle(index: 1, titleID: "PCSE00001", name: long),
            PresenceSettings(stateText: long, largeImageKey: "vita")
        ))
        #expect(result.details == cut)
        #expect(result.state == cut)
        #expect(result.assets?.largeText == cut)
        #expect(result.details?.utf16.count == 128)
    }

    @Test func resultIsAlwaysSanitized() throws {
        let title = VitaTitle(index: 1, titleID: "PCSE00001", name: String(repeating: "😺", count: 100))
        let result = try #require(activity(title, PresenceSettings(stateText: "  x  ")))
        #expect(result == result.sanitized())
        #expect(try #require(result.details).utf16.count <= 128)
    }
}

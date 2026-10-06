import DiscordIPC
import Foundation
import Testing
import VitaKit
@testable import PresenceKit

/// How the controller adds the running game's artwork to the presence.
@Suite struct PresenceControllerArtworkTests {
    private let personaImage = DiscordActivity.Assets(
        largeImage: personaArt.absoluteString,
        largeText: "Persona 4 Golden (PCSE00120)"
    )

    // MARK: Text first, then the artwork

    @Test func textIsShownRightAwayAndTheArtworkOnceItsLookupFinishes() async throws {
        let artwork = FakeArtwork([persona.titleID: personaArt])
        await artwork.hold(persona.titleID)
        try await withController(artwork: artwork) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.discord.accepted.count == 1 })
            #expect(await eventually { await artwork.lookedUp == [persona.titleID] })
            let text = try #require(await h.discord.acceptedActivities.last ?? nil)
            #expect(text.name == persona.name)
            #expect(text.details == "PlayStation Vita")
            #expect(text.assets == nil)
            #expect(await h.controller.snapshot.artwork == nil)

            // Polling goes on while the lookup is pending, and sends nothing new.
            let polls = await h.fetcher.callCount
            #expect(await eventually { await h.fetcher.callCount >= polls + 3 })
            #expect(await h.discord.accepted.count == 1)

            await artwork.release(persona.titleID)
            #expect(await eventually { await h.discord.accepted.count == 2 })
            var expected = text
            expected.assets = personaImage
            let withArtwork = try #require(await h.discord.acceptedActivities.last ?? nil)
            #expect(withArtwork == expected)
            let snapshot = await h.controller.snapshot
            #expect(snapshot.artwork == personaArt)
            #expect(snapshot.publishedActivity == withArtwork)
        }
    }

    @Test func artworkArrivingRightAfterTheTextWaitsForTheRateLimit() async throws {
        let artwork = FakeArtwork([persona.titleID: personaArt])
        await artwork.hold(persona.titleID)
        try await withController(artwork: artwork, configure: {
            $0.activityBurst = 1
            $0.activityWindow = .milliseconds(800)
        }) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.discord.accepted.count == 1 })
            await artwork.release(persona.titleID)
            #expect(await eventually { await h.controller.snapshot.artwork == personaArt })
            #expect(await eventually(timeout: .seconds(3)) { await h.discord.accepted.count == 2 })

            let sent = await h.discord.accepted
            #expect(sent[0].activity?.assets == nil)
            #expect(sent[1].activity?.assets == personaImage)
            #expect(sent[1].at - sent[0].at >= .milliseconds(790), "at most activityBurst updates per activityWindow")
        }
    }

    // MARK: One lookup per title

    @Test func eachTitleIsLookedUpOnceAndRemembered() async throws {
        let artwork = FakeArtwork([persona.titleID: personaArt, gravityRush.titleID: gravityRushArt])
        let fetcher = FakeFetcher(.title(persona))
        try await withController(fetcher, artwork: artwork) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.publishedActivity?.assets == personaImage })
            let polls = await fetcher.callCount
            #expect(await eventually { await fetcher.callCount >= polls + 5 })
            #expect(await artwork.lookedUp == [persona.titleID])

            await fetcher.setSteps(.title(gravityRush))
            #expect(await eventually {
                await h.controller.snapshot.publishedActivity?.assets?.largeImage == gravityRushArt.absoluteString
            })

            // Back on Persona, its artwork is in the very first update.
            await fetcher.setSteps(.title(persona))
            #expect(await eventually { await h.controller.snapshot.publishedActivity?.name == persona.name })
            let sinceSwitch = await h.discord.acceptedActivities.reversed().prefix { $0?.name == persona.name }
            #expect(!sinceSwitch.isEmpty)
            #expect(sinceSwitch.allSatisfy { $0?.assets == personaImage })
            let pollsLater = await fetcher.callCount
            #expect(await eventually { await fetcher.callCount >= pollsLater + 3 })
            #expect(await artwork.lookedUp == [persona.titleID, gravityRush.titleID])
        }
    }

    @Test func aMissIsRememberedToo() async throws {
        let artwork = FakeArtwork()
        try await withController(artwork: artwork) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.fetcher.callCount >= 6 })
            #expect(await artwork.lookedUp == [persona.titleID])
            #expect(await h.discord.acceptedActivities.count == 1)
            #expect(await h.controller.snapshot.artwork == nil)
        }
    }

    @Test func anotherContentIDIsLookedUpButANewNameIsNot() async throws {
        let withContentID = VitaTitle(
            index: persona.index,
            titleID: persona.titleID,
            name: persona.name,
            contentID: "UP0005-PCSE00120_00-PERSONA4GOLDEN01"
        )
        let artwork = FakeArtwork([persona.titleID: personaArt])
        let fetcher = FakeFetcher(.title(persona))
        try await withController(fetcher, artwork: artwork) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.artwork == personaArt })

            await fetcher.setSteps(.title(withContentID))
            #expect(await eventually { await artwork.calls.count == 2 })
            #expect(await artwork.calls.last == withContentID)

            var renamed = withContentID
            renamed.name = "Persona 4 Golden (EU)"
            await fetcher.setSteps(.title(renamed))
            #expect(await eventually {
                await h.controller.snapshot.publishedActivity?.assets?.largeText == "Persona 4 Golden (EU) (PCSE00120)"
            })
            let polls = await fetcher.callCount
            #expect(await eventually { await fetcher.callCount >= polls + 3 })
            #expect(await artwork.calls.count == 2)
            #expect(await h.controller.snapshot.artwork == personaArt)
        }
    }

    // MARK: Stale results

    @Test func aLateResultForThePreviousTitleIsIgnored() async throws {
        let artwork = FakeArtwork([persona.titleID: personaArt])
        await artwork.hold(persona.titleID)
        let fetcher = FakeFetcher(.title(persona))
        try await withController(fetcher, artwork: artwork) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await artwork.lookedUp == [persona.titleID] })

            await fetcher.setSteps(.title(gravityRush))
            #expect(await eventually { await h.controller.snapshot.publishedActivity?.name == gravityRush.name })
            #expect(await eventually { await artwork.answered == [gravityRush.titleID] })

            // Persona's abandoned lookup answers while Gravity Rush, which has no artwork, is running.
            await artwork.release(persona.titleID)
            #expect(await eventually { await artwork.answered.count == 2 })
            #expect(await stays(for: .milliseconds(150)) { await h.controller.snapshot.artwork == nil })
            #expect(await h.discord.attempts.allSatisfy { $0?.assets == nil })

            // Nor was the result kept: back on Persona, it is looked up again.
            await fetcher.setSteps(.title(persona))
            #expect(await eventually { await h.controller.snapshot.publishedActivity?.assets == personaImage })
            #expect(await artwork.lookedUp == [persona.titleID, gravityRush.titleID, persona.titleID])
        }
    }

    @Test func aLookupCutShortByATitleChangeIsntRememberedAsAMiss() async throws {
        let artwork = FakeArtwork([persona.titleID: personaArt], delay: .milliseconds(300))
        let fetcher = FakeFetcher(.title(persona))
        try await withController(fetcher, artwork: artwork) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await artwork.lookedUp == [persona.titleID] })

            await fetcher.setSteps(.title(gravityRush))
            #expect(await eventually { await artwork.cancelledCalls == 1 })
            #expect(await eventually { await artwork.lookedUp == [persona.titleID, gravityRush.titleID] })

            await artwork.setDelay(nil)
            await fetcher.setSteps(.title(persona))
            #expect(await eventually { await h.controller.snapshot.publishedActivity?.assets == personaImage })
            #expect(await artwork.lookedUp == [persona.titleID, gravityRush.titleID, persona.titleID])
        }
    }

    @Test func anAddressChangeAbandonsALookupInProgress() async throws {
        let artwork = FakeArtwork([persona.titleID: personaArt])
        await artwork.hold(persona.titleID)
        let fetcher = FakeFetcher(.title(persona))
        await fetcher.setStep(.title(gravityRush), forHost: "192.168.1.21")
        try await withController(fetcher, artwork: artwork, configure: { $0.pollIntervalOverride = .seconds(30) }) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await artwork.lookedUp == [persona.titleID] })

            var settings = PresenceSettings.valid
            settings.address = "192.168.1.21"
            await h.controller.updateSettings(settings)
            #expect(await eventually { await h.controller.snapshot.publishedActivity?.name == gravityRush.name })

            await artwork.release(persona.titleID)
            #expect(await eventually { await artwork.answered.count == 2 })
            #expect(await stays(for: .milliseconds(150)) { await h.controller.snapshot.artwork == nil })
            #expect(await h.discord.attempts.allSatisfy { $0?.assets == nil })

            // The abandoned result wasn't kept for Persona either.
            await fetcher.setStep(.title(persona), forHost: "192.168.1.21")
            await h.controller.pollNow()
            #expect(await eventually { await h.controller.snapshot.publishedActivity?.assets == personaImage })
            #expect(await artwork.lookedUp == [persona.titleID, gravityRush.titleID, persona.titleID])
        }
    }

    @Test func stopAbandonsALookupInProgress() async throws {
        let artwork = FakeArtwork([persona.titleID: personaArt])
        await artwork.hold(persona.titleID)
        try await withController(artwork: artwork) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await artwork.calls.count == 1 })

            await h.controller.stop()
            await artwork.release(persona.titleID)
            #expect(await eventually { await artwork.answered.count == 1 })
            #expect(await stays(for: .milliseconds(100)) { await h.controller.snapshot == .idle })
            #expect(await h.discord.attempts.allSatisfy { $0?.assets == nil })
        }
    }

    @Test func eachRunLooksTitlesUpAgain() async throws {
        let artwork = FakeArtwork([persona.titleID: personaArt])
        try await withController(artwork: artwork) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.publishedActivity?.assets == personaImage })
            await h.controller.stop()
            #expect(await h.controller.snapshot.artwork == nil)

            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.publishedActivity?.assets == personaImage })
            #expect(await artwork.lookedUp == [persona.titleID, persona.titleID])
        }
    }

    // MARK: Settings

    @Test func noLookupsAndNoImageWhileArtworkIsOff() async throws {
        let artwork = FakeArtwork([persona.titleID: personaArt])
        var settings = PresenceSettings.valid
        settings.showGameArtwork = false
        try await withController(artwork: artwork) { h in
            await h.controller.start(with: settings)
            #expect(await eventually { await h.controller.snapshot.publishedActivity != nil })
            let polls = await h.fetcher.callCount
            #expect(await eventually { await h.fetcher.callCount >= polls + 5 })
            #expect(await artwork.calls.isEmpty)
            #expect(await h.discord.acceptedActivities.count == 1)
            #expect(await h.controller.snapshot.publishedActivity?.assets == nil)
            #expect(await h.controller.snapshot.artwork == nil)
        }
    }

    @Test func turningArtworkOnLooksUpTheTitleAndTurningItOffDropsTheImage() async throws {
        let artwork = FakeArtwork([persona.titleID: personaArt])
        var settings = PresenceSettings.valid
        settings.showGameArtwork = false
        try await withController(artwork: artwork) { h in
            await h.controller.start(with: settings)
            #expect(await eventually { await h.controller.snapshot.publishedActivity != nil })

            settings.showGameArtwork = true
            await h.controller.updateSettings(settings)
            #expect(await eventually { await h.controller.snapshot.publishedActivity?.assets == personaImage })
            #expect(await h.controller.snapshot.artwork == personaArt)
            #expect(await artwork.lookedUp == [persona.titleID])

            settings.showGameArtwork = false
            await h.controller.updateSettings(settings)
            #expect(await h.controller.snapshot.artwork == nil)
            #expect(await eventually { await h.controller.snapshot.publishedActivity?.assets == nil })
            #expect(await h.controller.snapshot.publishedActivity?.name == persona.name)

            // The result was kept, so turning artwork on again shows it without another lookup.
            settings.showGameArtwork = true
            await h.controller.updateSettings(settings)
            #expect(await h.controller.snapshot.artwork == personaArt)
            #expect(await eventually { await h.controller.snapshot.publishedActivity?.assets == personaImage })
            #expect(await artwork.lookedUp == [persona.titleID])
            #expect(await h.discord.accepted.count == 4)
        }
    }

    @Test func turningArtworkOffAbandonsALookupInProgress() async throws {
        let artwork = FakeArtwork([persona.titleID: personaArt])
        await artwork.hold(persona.titleID)
        try await withController(artwork: artwork) { h in
            var settings = PresenceSettings.valid
            await h.controller.start(with: settings)
            #expect(await eventually { await artwork.calls.count == 1 })

            settings.showGameArtwork = false
            await h.controller.updateSettings(settings)
            await artwork.release(persona.titleID)
            #expect(await eventually { await artwork.answered.count == 1 })
            #expect(await stays(for: .milliseconds(150)) { await h.controller.snapshot.artwork == nil })
            #expect(await h.discord.attempts.allSatisfy { $0?.assets == nil })

            // Its result wasn't kept: turning artwork on again looks the title up again.
            settings.showGameArtwork = true
            await h.controller.updateSettings(settings)
            #expect(await eventually { await h.controller.snapshot.publishedActivity?.assets == personaImage })
            #expect(await artwork.calls.count == 2)
        }
    }

    @Test func aCustomImageReplacesTheArtwork() async throws {
        let artwork = FakeArtwork([persona.titleID: personaArt])
        var settings = PresenceSettings.valid
            settings.largeImageKey = "vita"
        try await withController(artwork: artwork) { h in
            await h.controller.start(with: settings)
            #expect(await eventually { await h.discord.accepted.count == 1 })
            let polls = await h.fetcher.callCount
            #expect(await eventually { await h.fetcher.callCount >= polls + 3 })
            #expect(await artwork.calls.isEmpty, "a custom image turns the lookup off")
            #expect(await h.controller.snapshot.artwork == nil)
            let sent = await h.discord.acceptedActivities
            #expect(sent.count == 1)
            #expect(sent.last??.assets == DiscordActivity.Assets(
                largeImage: "vita",
                largeText: "Persona 4 Golden (PCSE00120)"
            ))

            // Clearing the custom image starts the lookup, and the picture shows when it finishes.
            settings.largeImageKey = ""
            await h.controller.updateSettings(settings)
            #expect(await eventually { await h.controller.snapshot.publishedActivity?.assets == personaImage })
            #expect(await artwork.calls.count == 1)
        }
    }

    // MARK: Titles without artwork

    @Test func theLiveAreaAndSystemAppsAreNeverLookedUp() async throws {
        let settingsApp = VitaTitle(index: 1, titleID: "NPXS10015", name: "Settings")
        let adrenalineMenu = VitaTitle(index: 2, titleID: "XMB", name: "Adrenaline XMB Menu")
        let adrenalineIcon = try #require(
            URL(string: "https://robin994.github.io/NeoVitaDB-Catalog/icons/0047-adrenaline.png")
        )
        // Results for every title, so a lookup that shouldn't happen would show.
        let artwork = FakeArtwork([
            VitaTitle.liveArea.titleID: personaArt,
            settingsApp.titleID: personaArt,
            adrenalineMenu.titleID: adrenalineIcon,
        ])
        let fetcher = FakeFetcher(.title(.liveArea))
        try await withController(fetcher, artwork: artwork) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.publishedActivity?.details == "In the LiveArea" })
            #expect(await h.controller.snapshot.publishedActivity?.name == "PlayStation Vita")
            #expect(
                await h.controller.snapshot.publishedActivity?.assets?.largeImage == PresenceBuilder.liveAreaImage
            )

            await fetcher.setSteps(.title(settingsApp))
            #expect(await eventually { await h.controller.snapshot.publishedActivity?.name == "Settings" })
            let polls = await fetcher.callCount
            #expect(await eventually { await fetcher.callCount >= polls + 3 })
            #expect(await artwork.calls.isEmpty, "a built-in app's icon is fixed; it isn't looked up")
            #expect(await h.controller.snapshot.artwork == nil)
            #expect(
                await h.controller.snapshot.publishedActivity?.assets?.largeImage
                    == SystemAppIcons.image(for: settingsApp.titleID)
            )

            // Adrenaline's menu is looked up: its artwork is Adrenaline's icon.
            await fetcher.setSteps(.title(adrenalineMenu))
            #expect(await eventually {
                await h.controller.snapshot.publishedActivity?.assets?.largeImage == adrenalineIcon.absoluteString
            })
            let shown = await h.controller.snapshot.publishedActivity
            #expect(shown?.name == "Adrenaline")
            #expect(shown?.details == "PlayStation Vita")
            #expect(shown?.assets?.largeText == "Adrenaline (XMB)")
            #expect(await artwork.lookedUp == [adrenalineMenu.titleID])
        }
    }

    // MARK: Snapshots

    @Test func snapshotArtworkFollowsTheTitle() async throws {
        let artwork = FakeArtwork([persona.titleID: personaArt, gravityRush.titleID: gravityRushArt])
        await artwork.hold(gravityRush.titleID)
        let fetcher = FakeFetcher(.title(persona))
        try await withController(fetcher, artwork: artwork) { h in
            let collector = SnapshotCollector()
            let consumer = Task {
                for await snapshot in h.controller.snapshots { await collector.append(snapshot) }
            }
            defer { consumer.cancel() }

            await h.controller.start(with: .valid)
            #expect(await eventually { await collector.all.last?.artwork == personaArt })

            // None while the next title is looked up.
            await fetcher.setSteps(.title(gravityRush))
            #expect(await eventually { await h.controller.snapshot.title == gravityRush })
            #expect(await h.controller.snapshot.artwork == nil)
            await artwork.release(gravityRush.titleID)
            #expect(await eventually { await collector.all.last?.artwork == gravityRushArt })

            // Gone with the title.
            await fetcher.setSteps(.failure(.timedOut))
            #expect(await eventually { await h.controller.snapshot.title == nil })
            #expect(await h.controller.snapshot.artwork == nil)

            await h.controller.stop()
            #expect(await eventually { await collector.all.last == .idle })
        }
    }
}

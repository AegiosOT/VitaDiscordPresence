import AppKit
import DiscordIPC
import Foundation
import os
import PresenceKit
import SwiftUI
import Testing
@testable import VitaPresenceApp
import VitaKit

@MainActor
struct AppModelTests {
    let temporary: TemporaryDefaults
    let controller = FakeController()
    let loginItem = FakeLoginItem()
    /// Wake notifications for this test's model only.
    let notifications = NotificationCenter()

    init() throws {
        temporary = try TemporaryDefaults()
    }

    var store: SettingsStore {
        SettingsStore(defaults: temporary.defaults)
    }

    /// A model over the fakes. Typing is committed after `commitDelay`, which is an hour unless a test waits
    /// for it.
    func makeModel(
        controller: FakeController? = nil,
        scanner: @escaping @Sendable () async throws -> [DiscoveredVita] = { [] },
        macLookup: @escaping @Sendable (String) -> MACAddress? = { _ in nil },
        commitDelay: Duration = .seconds(3600)
    ) -> AppModel {
        let controller = controller ?? self.controller
        return AppModel(
            store: store,
            makeController: { _ in controller },
            scanner: scanner,
            macLookup: macLookup,
            loginItem: loginItem.launchAtLogin,
            wakeNotifications: notifications,
            commitDelay: commitDelay
        )
    }

    // MARK: Launch

    @Test func loadsTheSavedSettings() {
        store.settings = validSettings
        store.connectOnLaunch = false

        let model = makeModel()

        #expect(model.settings == validSettings)
        #expect(model.connectOnLaunch == false)
        #expect(model.isActive == false)
        #expect(model.snapshot == .idle)
        #expect(model.launchAtLogin == .disabled)
    }

    @Test func firstRunConnectsWithTheDefaults() async {
        let model = makeModel()

        // The defaults work: the Vita is found automatically and the built-in Discord application is used.
        #expect(model.launch() == .connected)
        #expect(model.isActive)
        #expect(await waitUntil { await controller.calls == [.start(PresenceSettings())] })

        // The menu says what is going on until the Vita is found.
        let looking = PresenceSnapshot(isRunning: true, vita: .resolving, discord: .connecting)
        controller.publish(looking)
        #expect(await waitUntil { model.snapshot == looking })
        #expect(StatusText.lines(for: model.snapshot, now: Date()).first == "Vita: Looking for your Vita…")
        #expect(model.discoveryStatus == "Looking for your Vita…")
        #expect(model.menuBarIcon == .standby)
    }

    @Test func unusableSavedSettingsOpenSettings() async {
        let broken = PresenceSettings(address: "192.168.", clientID: "12345")
        store.settings = broken
        let model = makeModel()

        #expect(model.launch() == .showSettings)
        // The controller waits for usable settings, so fixing them is all it takes.
        #expect(model.isActive)
        #expect(await waitUntil { await controller.calls == [.start(broken)] })
    }

    @Test func theControllerStartsFromWhereTheVitaAnsweredLastTime() {
        var given: [String?] = []
        // Each model gets its own controller, as each launch does.
        let makeController: (RememberedVita) -> any PresenceControlling = { remembered in
            given.append(remembered.host)
            return FakeController()
        }

        _ = AppModel(store: store, makeController: makeController, loginItem: loginItem.launchAtLogin)
        store.lastVitaHost = "192.168.1.20"
        _ = AppModel(store: store, makeController: makeController, loginItem: loginItem.launchAtLogin)

        #expect(given == [nil, "192.168.1.20"])
    }

    @Test func whereTheVitaAnswersIsSavedForTheNextLaunch() async {
        let model = makeModel()

        // Only an answer counts, not an address that is still being tried.
        let trying = PresenceSnapshot(isRunning: true, vita: .connecting, host: "192.168.1.20")
        controller.publish(trying)
        #expect(await waitUntil { model.snapshot == trying })
        #expect(store.lastVitaHost == nil)

        controller.publish(PresenceSnapshot(isRunning: true, vita: .connected, host: "192.168.1.20"))
        #expect(await waitUntil { store.lastVitaHost == "192.168.1.20" })

        let failing = PresenceSnapshot(isRunning: true, vita: .failing(.timedOut, failures: 1), host: "192.168.1.31")
        controller.publish(failing)
        #expect(await waitUntil { model.snapshot == failing })
        #expect(store.lastVitaHost == "192.168.1.20")

        // The Vita moved to another address.
        controller.publish(PresenceSnapshot(isRunning: true, vita: .connected, host: "192.168.1.31"))
        #expect(await waitUntil { store.lastVitaHost == "192.168.1.31" })
        controller.publish(.idle)
        #expect(await waitUntil { model.snapshot == .idle })
        #expect(store.lastVitaHost == "192.168.1.31", "stopping keeps it")
        #expect(model.profiles.count == 1)
        #expect(model.profiles[0].lastAddress == "192.168.1.31")
        #expect(model.selectedProfileID == model.profiles[0].id)
    }

    @Test func aLaterAddressUpdatesTheSameProfile() async {
        let mac = MACAddress(bytes: [0xA4, 0x5E, 0x60, 0x01, 0x02, 0x03])
        let model = makeModel(macLookup: { host in host == "192.168.1.31" ? mac : nil })

        controller.publish(PresenceSnapshot(isRunning: true, vita: .connected, host: "192.168.1.20"))
        #expect(await waitUntil { model.profiles.count == 1 })
        let id = model.profiles[0].id
        #expect(model.profiles[0].macAddress == nil)

        controller.publish(PresenceSnapshot(isRunning: true, vita: .connected, host: "192.168.1.31"))
        #expect(await waitUntil { model.profiles.first?.lastAddress == "192.168.1.31" })
        #expect(model.profiles.count == 1)
        #expect(model.profiles[0].id == id)
        #expect(model.profiles[0].macAddress == "a4:5e:60:01:02:03")
        #expect(store.lastVitaHost == "192.168.1.31")
    }

    @Test func launchWithoutConnectOnLaunchWaitsForTheUser() async {
        store.connectOnLaunch = false
        let model = makeModel()

        #expect(model.launch() == .none)
        #expect(model.isActive == false)
        // Commands arrive in order, so anything sent at launch would come before this one.
        model.updateSettings { $0.stateText = "marker" }
        #expect(await waitUntil { await controller.calls.count == 1 })
        #expect(await controller.calls == [.update(model.settings)])
    }

    @Test func launchConnectsWithUsableSettings() async {
        store.settings = validSettings
        let model = makeModel()

        #expect(model.launch() == .connected)
        #expect(model.isActive)
        #expect(await waitUntil { await controller.calls.first == .start(validSettings) })
    }

    @Test func launchWaitsWhenConnectOnLaunchIsOff() async {
        store.settings = validSettings
        store.connectOnLaunch = false
        let model = makeModel()

        #expect(model.launch() == .none)
        #expect(model.isActive == false)
        model.updateSettings { $0.stateText = "marker" }
        #expect(await waitUntil { await controller.calls.count == 1 })
        #expect(await controller.calls == [.update(model.settings)])
    }

    @Test func launchingNeverRegistersALoginItem() {
        store.settings = validSettings
        let model = makeModel()

        _ = model.launch()

        #expect(loginItem.requests.isEmpty)
    }

    // MARK: Connection

    @Test func connectionCommandsReachTheControllerInOrder() async {
        store.settings = validSettings
        let model = makeModel()

        model.connect()
        #expect(model.isActive)
        model.disconnect()
        #expect(model.isActive == false)
        model.toggleConnection()
        #expect(model.isActive)
        model.toggleConnection()
        #expect(model.isActive == false)

        #expect(await waitUntil { await controller.calls.count == 4 })
        #expect(await controller.calls == [.start(validSettings), .stop, .start(validSettings), .stop])
    }

    @Test func pollNowOnlyWhileConnected() async {
        let model = makeModel()

        model.pollNow()
        model.connect()
        model.pollNow()

        #expect(await waitUntil { await controller.calls.count == 2 })
        #expect(await controller.calls == [.start(model.settings), .pollNow])
    }

    @Test func wakingUpPollsWhileConnected() async {
        store.settings = validSettings
        let model = makeModel()
        #expect(model.launch() == .connected)

        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await waitUntil { await controller.calls == [.start(validSettings), .pollNow] })

        model.disconnect()
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await waitUntil { await controller.calls.count == 3 })
        #expect(await stays(for: .milliseconds(100)) {
            await controller.calls == [.start(validSettings), .pollNow, .stop]
        })
    }

    @Test func snapshotsArePublished() async {
        let model = makeModel()
        let snapshot = PresenceSnapshot(isRunning: true, vita: .connected, discord: .connecting, host: "192.168.1.20")

        controller.publish(snapshot)

        #expect(await waitUntil { model.snapshot == snapshot })
    }

    @Test func iconAndLocalNetworkPromptFollowTheState() async {
        store.settings = validSettings
        let model = makeModel()
        #expect(model.menuBarIcon == .standby)
        #expect(model.needsLocalNetworkAccess == false)

        let denied = PresenceSnapshot(isRunning: true, vita: .failing(.localNetworkDenied, failures: 2))
        controller.publish(denied)
        #expect(await waitUntil { model.snapshot == denied })
        #expect(model.menuBarIcon == .attention)
        #expect(model.needsLocalNetworkAccess)

        let showing = PresenceSnapshot(
            isRunning: true,
            vita: .connected,
            publishedActivity: DiscordActivity(details: "Persona 4 Golden")
        )
        controller.publish(showing)
        #expect(await waitUntil { model.snapshot == showing })
        #expect(model.menuBarIcon == .presence)
        #expect(model.needsLocalNetworkAccess == false)

        model.updateSettings { $0.clientID = "123" }
        #expect(model.menuBarIcon == .attention)
    }

    // MARK: Settings window

    @Test func theVitaSectionSaysWhereTheVitaWasFound() async {
        let model = makeModel()
        #expect(model.discoveryStatus == nil, "nothing to say while disconnected")

        typealias Issue = PresenceSettings.Issue
        let looking = "Looking for your Vita…"
        let cases: [(PresenceSnapshot, String?)] = [
            (PresenceSnapshot(isRunning: true, vita: .resolving), looking),
            (PresenceSnapshot(isRunning: true, vita: .connecting, host: "192.168.1.20"), looking),
            (PresenceSnapshot(isRunning: true, vita: .connected, host: "192.168.1.20"), "Found at 192.168.1.20"),
            (
                PresenceSnapshot(isRunning: true, vita: .failing(.timedOut, failures: 3), host: "192.168.1.20"),
                "Last found at 192.168.1.20"
            ),
            (PresenceSnapshot(isRunning: true, vita: .failing(.localNetworkDenied, failures: 1)), looking),
            (
                PresenceSnapshot(isRunning: true, vita: .failing(.unresolvedAddress("No Vita found."), failures: 1)),
                "No Vita found."
            ),
            (PresenceSnapshot(isRunning: true, vita: .misconfigured(Issue.invalidClientID.message)), nil),
            (.idle, nil),
        ]
        for (snapshot, expected) in cases {
            controller.publish(snapshot)
            #expect(await waitUntil { model.snapshot == snapshot })
            #expect(model.discoveryStatus == expected, "\(snapshot.vita)")
        }
    }

    @Test func theDiscoveryStatusIsOnlyForAutomaticDiscovery() async {
        let model = makeModel()
        let found = PresenceSnapshot(isRunning: true, vita: .connected, host: "192.168.1.20")
        controller.publish(found)
        #expect(await waitUntil { model.discoveryStatus == "Found at 192.168.1.20" })

        // Gone as soon as an address is typed, before it is saved...
        model.textBinding(for: \.address).wrappedValue = "192.168.1.31"
        #expect(model.discoveryStatus == nil)
        model.commitDraft()
        #expect(model.discoveryStatus == nil)
        // ...and while the field is cleared but not saved yet.
        model.textBinding(for: \.address).wrappedValue = ""
        #expect(model.discoveryStatus == nil)

        // "auto" means automatic too.
        model.updateSettings { $0.address = " Auto " }
        #expect(model.discoveryStatus == "Found at 192.168.1.20")
    }

    @Test func theBuiltInDiscordApplicationIsUsedUnlessTheUserHasTheirOwn() async {
        let model = makeModel()
        #expect(model.usesOwnDiscordApplication == false)
        #expect(model.ownDiscordApplicationBinding.wrappedValue == false)

        // Turning it on only shows the field; blank still means the built-in application.
        model.ownDiscordApplicationBinding.wrappedValue = true
        #expect(model.usesOwnDiscordApplication)
        #expect(model.settings == PresenceSettings())

        model.textBinding(for: \.clientID).wrappedValue = validSettings.clientID
        model.commitDraft()
        #expect(store.settings.clientID == validSettings.clientID)

        // Turning it off goes back to the built-in application right away.
        model.ownDiscordApplicationBinding.wrappedValue = false
        #expect(model.usesOwnDiscordApplication == false)
        #expect(model.settings == PresenceSettings())
        #expect(store.settings == PresenceSettings())
        #expect(await waitUntil {
            await controller.calls == [
                .update(PresenceSettings(clientID: validSettings.clientID)),
                .update(PresenceSettings()),
            ]
        })
    }

    @Test func aSavedApplicationIDShowsItsField() {
        store.settings = validSettings

        #expect(makeModel().usesOwnDiscordApplication)
    }

    @Test func turningOffTheOwnApplicationDiscardsAnIDBeingTyped() async {
        let model = makeModel()
        model.setUsesOwnDiscordApplication(true)
        model.textBinding(for: \.clientID).wrappedValue = "1234"

        model.setUsesOwnDiscordApplication(false)

        #expect(model.draft == PresenceSettings())
        #expect(model.settings == PresenceSettings())
        #expect(await stays(for: .milliseconds(100)) { await controller.calls.isEmpty })
    }

    @Test func findOnNetworkMarksTheVitaInUse() async throws {
        let mac = try #require(MACAddress("a4:5e:60:01:02:03"))
        let first = DiscoveredVita(ipAddress: "192.168.1.20", macAddress: nil, title: .liveArea)
        let second = DiscoveredVita(ipAddress: "192.168.1.31", macAddress: mac, title: .liveArea)
        let model = makeModel()

        // Automatic: the Vita being polled, once there is one.
        #expect(!model.isInUse(first) && !model.isInUse(second))
        let atFirst = PresenceSnapshot(isRunning: true, vita: .connected, host: "192.168.1.20")
        controller.publish(atFirst)
        #expect(await waitUntil { model.snapshot == atFirst })
        #expect(model.isInUse(first) && !model.isInUse(second))

        // An IP address: the Vita at that address, as soon as it's typed.
        model.textBinding(for: \.address).wrappedValue = " 192.168.1.31 "
        #expect(!model.isInUse(first) && model.isInUse(second))

        // A MAC address: the Vita with that MAC address, or the one it was resolved to.
        model.updateSettings { $0.address = "A4-5E-60-01-02-03" }
        let resolving = PresenceSnapshot(isRunning: true, vita: .resolving)
        controller.publish(resolving)
        #expect(await waitUntil { model.snapshot == resolving })
        #expect(!model.isInUse(first) && model.isInUse(second))
        controller.publish(atFirst)
        #expect(await waitUntil { model.snapshot == atFirst })
        #expect(model.isInUse(first) && model.isInUse(second))

        // Nothing is in use while the address is invalid.
        model.textBinding(for: \.address).wrappedValue = "192.168."
        #expect(!model.isInUse(first) && !model.isInUse(second))
    }

    @Test func theThumbnailIsTheImageFriendsSee() async {
        let model = makeModel()
        #expect(model.largeImageURL == nil)

        let artwork = "https://store.playstation.com/store/api/chihiro/00_09_000/container/US/en/19/"
            + "UP0005-PCSE00120_00-PERSONA4GOLDEN01/1534563384000/image"
        let custom = "HTTPS://example.com/vita.png"
        let cases: [(DiscordActivity.Assets?, URL?)] = [
            (DiscordActivity.Assets(largeImage: artwork, largeText: "Persona 4 Golden"), URL(string: artwork)),
            (DiscordActivity.Assets(largeImage: custom), URL(string: custom)),
            // An asset key of the user's own application: only Discord can show it.
            (DiscordActivity.Assets(largeImage: "vita-logo"), nil),
            (DiscordActivity.Assets(largeImage: nil, smallImage: artwork), nil),
            (nil, nil),
        ]
        for (assets, expected) in cases {
            let activity = DiscordActivity(name: "Persona 4 Golden", details: "PlayStation Vita", assets: assets)
            let snapshot = PresenceSnapshot(isRunning: true, vita: .connected, publishedActivity: activity)
            controller.publish(snapshot)
            #expect(await waitUntil { model.snapshot == snapshot })
            #expect(model.largeImageURL == expected, "\(String(describing: assets))")
        }

        // Found artwork that Discord doesn't show (it isn't connected) is no thumbnail either.
        let notShown = PresenceSnapshot(isRunning: true, vita: .connected, artwork: URL(string: artwork))
        controller.publish(notShown)
        #expect(await waitUntil { model.snapshot == notShown })
        #expect(model.largeImageURL == nil)
    }

    // MARK: Settings

    @Test func settingsChangesAreSavedAndApplied() async {
        let model = makeModel()

        model.updateSettings { $0.address = "192.168.1.20" }

        #expect(model.settings.address == "192.168.1.20")
        #expect(store.settings.address == "192.168.1.20")
        #expect(await waitUntil { await controller.calls == [.update(model.settings)] })
    }

    @Test func unchangedSettingsAreIgnored() async {
        let model = makeModel()

        model.updateSettings { $0.address = "" }
        model.updateSettings { $0.stateText = "marker" }

        #expect(await waitUntil { await controller.calls.count == 1 })
        #expect(await controller.calls == [.update(model.settings)])
    }

    @Test func rapidChangesArriveInOrder() async {
        let model = makeModel()
        let intervals = (3...52).map(Double.init)

        for interval in intervals {
            model.updateSettings { $0.pollInterval = interval }
        }

        let expected = intervals.map { FakeController.Call.update(PresenceSettings(pollInterval: $0)) }
        #expect(await waitUntil { await controller.calls.count == expected.count })
        #expect(await controller.calls == expected)
    }

    @Test func connectOnLaunchIsSaved() {
        let model = makeModel()

        model.setConnectOnLaunch(false)

        #expect(model.connectOnLaunch == false)
        #expect(store.connectOnLaunch == false)
    }

    @Test func bindingsReadAndWriteTheModel() {
        let model = makeModel()

        let stateText = model.textBinding(for: \.stateText)
        stateText.wrappedValue = "Grinding"
        #expect(stateText.wrappedValue == "Grinding")
        #expect(model.draft.stateText == "Grinding")
        #expect(store.settings.stateText == "", "typing is saved once it pauses")

        let elapsedTime = model.binding(for: \.showElapsedTime)
        elapsedTime.wrappedValue = false
        #expect(elapsedTime.wrappedValue == false)
        #expect(store.settings == PresenceSettings(stateText: "Grinding", showElapsedTime: false))

        model.connectOnLaunchBinding.wrappedValue = false
        #expect(model.connectOnLaunch == false)

        #expect(model.launchAtLoginBinding.wrappedValue == false)
        model.launchAtLoginBinding.wrappedValue = true
        #expect(loginItem.requests == [true])
        #expect(model.launchAtLoginBinding.wrappedValue)
    }

    @Test func pollIntervalBindingStaysInTheAllowedRange() {
        let model = makeModel()
        let interval = model.pollIntervalBinding

        interval.wrappedValue = 1000
        #expect(model.settings.pollInterval == PresenceSettings.pollIntervalRange.upperBound)
        interval.wrappedValue = 1
        #expect(model.settings.pollInterval == PresenceSettings.pollIntervalRange.lowerBound)
        interval.wrappedValue = 42
        #expect(model.settings.pollInterval == 42)
        interval.wrappedValue = .nan
        #expect(model.settings.pollInterval == 42)
    }

    // MARK: Typing

    @Test func typingIsCommittedOnceItPauses() async {
        let model = makeModel(commitDelay: .milliseconds(100))
        let address = model.textBinding(for: \.address)

        for text in ["1", "192.168", "192.168.1.20"] {
            address.wrappedValue = text
        }

        // What is typed shows, and is checked, right away...
        #expect(address.wrappedValue == "192.168.1.20")
        #expect(model.draft.issues.isEmpty)
        // ...but it is saved and applied once, after the pause.
        #expect(model.settings.address == "")
        #expect(store.settings.address == "")
        #expect(await waitUntil { await controller.calls == [.update(PresenceSettings(address: "192.168.1.20"))] })
        #expect(model.settings.address == "192.168.1.20")
        #expect(store.settings.address == "192.168.1.20")
        #expect(await stays(for: .milliseconds(200)) { await controller.calls.count == 1 })
    }

    @Test func returnCommitsRightAway() async {
        let model = makeModel()
        model.textBinding(for: \.clientID).wrappedValue = validSettings.clientID

        model.commitDraft()

        #expect(model.settings.clientID == validSettings.clientID)
        #expect(store.settings.clientID == validSettings.clientID)
        #expect(await waitUntil { await controller.calls == [.update(model.settings)] })
    }

    @Test func connectingCommitsTheDraftFirst() async {
        let model = makeModel()
        model.textBinding(for: \.address).wrappedValue = validSettings.address
        model.textBinding(for: \.clientID).wrappedValue = validSettings.clientID

        model.connect()

        #expect(store.settings == validSettings)
        #expect(await waitUntil { await controller.calls == [.update(validSettings), .start(validSettings)] })
    }

    @Test func immediateChangesTakeTheDraftAlong() async {
        let model = makeModel()
        model.textBinding(for: \.stateText).wrappedValue = "Grinding"

        model.updateSettings { $0.showLiveArea = false }

        let expected = PresenceSettings(stateText: "Grinding", showLiveArea: false)
        #expect(model.settings == expected)
        #expect(await waitUntil { await controller.calls == [.update(expected)] })
    }

    @Test func quittingSavesTheDraft() async {
        let model = makeModel()
        model.textBinding(for: \.stateText).wrappedValue = "Grinding"

        await model.shutdown()

        #expect(store.settings.stateText == "Grinding")
        #expect(await waitUntil { await controller.calls == [.update(model.settings), .stop] })
    }

    @Test func theIconFollowsTheSavedSettingsNotTheDraft() {
        store.settings = validSettings
        let model = makeModel()

        model.textBinding(for: \.address).wrappedValue = "192.168."
        #expect(model.draft.issues == [.invalidAddress])
        #expect(model.menuBarIcon == .standby)

        model.commitDraft()
        #expect(model.menuBarIcon == .attention)
    }

    // MARK: Scanning

    @Test func scanResultsCanFillInTheAddress() async {
        let found = [
            DiscoveredVita(ipAddress: "192.168.1.20", macAddress: nil, title: .liveArea),
            DiscoveredVita(
                ipAddress: "192.168.1.31",
                macAddress: MACAddress(bytes: [0xA4, 0x5E, 0x60, 0x01, 0x02, 0x03]),
                title: VitaTitle(index: 1, titleID: "PCSE00120", name: "Persona 4 Golden")
            ),
        ]
        let model = makeModel(scanner: { found })

        model.scan()
        #expect(model.scanState == .scanning)
        #expect(await waitUntil { model.scanState == .results(found) })

        model.choose(found[1])
        // The address stays automatic, so a later IP change can still be followed by MAC address.
        #expect(model.settings.address == "")
        #expect(model.profiles.count == 1)
        #expect(model.profiles[0].lastAddress == "192.168.1.31")
        #expect(model.profiles[0].macAddress == "a4:5e:60:01:02:03")
        #expect(model.selectedProfileID == model.profiles[0].id)
        #expect(store.lastVitaHost == "192.168.1.31")
        let profile = model.profiles[0]
        #expect(await waitUntil {
            await controller.calls == [
                .remember(host: "192.168.1.31", macAddress: profile.mac),
                .start(model.settings),
            ]
        })
    }

    @Test func deniedScanOffersLocalNetworkAccess() async {
        let denied = OSAllocatedUnfairLock(initialState: true)
        let model = makeModel(scanner: {
            if denied.withLock({ $0 }) { throw VitaConnectionError.localNetworkDenied }
            return []
        })

        model.scan()
        #expect(await waitUntil { model.scanState == .failed(VitaConnectionError.localNetworkDenied.userMessage) })
        #expect(model.scanNeedsLocalNetworkAccess)

        denied.withLock { $0 = false }
        model.scan()
        #expect(model.scanNeedsLocalNetworkAccess == false)
        #expect(await waitUntil { model.scanState == .results([]) })
    }

    @Test func otherScanFailuresShowTheirMessage() async {
        let model = makeModel(scanner: { throw TestError() })

        model.scan()

        #expect(await waitUntil { model.scanState == .failed("Something went wrong") })
        #expect(model.scanNeedsLocalNetworkAccess == false)
    }

    @Test func aSecondScanWaitsForTheFirst() async {
        let scans = Counter()
        let model = makeModel(scanner: {
            scans.increment()
            try await Task.sleep(for: .milliseconds(100))
            return []
        })

        model.scan()
        model.scan()

        #expect(await waitUntil { model.scanState == .results([]) })
        #expect(scans.value == 1)
    }

    // MARK: Quitting

    @Test func shutdownStopsTheController() async {
        store.settings = validSettings
        let slow = FakeController(stopDuration: .milliseconds(100))
        let model = makeModel(controller: slow)
        model.connect()
        let start = ContinuousClock.now

        await model.shutdown()

        #expect(ContinuousClock.now - start >= .milliseconds(100), "shutdown waits for the controller to stop")
        #expect(model.isActive == false)
        #expect(await waitUntil { await slow.calls == [.start(validSettings), .stop] })
    }

    @Test func shutdownGivesUpOnAHungController() async {
        let hung = FakeController(stopDuration: .seconds(5))
        let model = makeModel(controller: hung)
        model.connect()
        #expect(await waitUntil { await hung.calls == [.start(model.settings)] })
        let start = ContinuousClock.now

        await model.shutdown(timeLimit: .milliseconds(200))

        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .milliseconds(200))
        #expect(elapsed < .seconds(2))
        // `stop()` keeps running after shutdown gave up on it.
        #expect(await waitUntil { await hung.calls.last == .stop })
    }

    @Test func shutdownCancelsARunningScan() async {
        let model = makeModel(scanner: {
            try await Task.sleep(for: .seconds(10))
            return []
        })

        model.scan()
        await model.shutdown()

        #expect(await waitUntil { model.scanState == .idle })
    }

    @Test func shuttingDownTwiceIsHarmless() async {
        let model = makeModel()

        await model.shutdown()
        await model.shutdown()

        #expect(await controller.calls == [.stop])
    }

    @Test func theModelIsReleasedWhenNoLongerUsed() async {
        weak var released: AppModel?
        do {
            let model = makeModel()
            _ = model.launch()
            model.connect()
            released = model
        }

        #expect(await waitUntil { released == nil })
    }

    // MARK: Launch at login

    @Test func turningLaunchAtLoginOnAndOff() {
        let model = makeModel()

        model.setLaunchAtLogin(true)
        #expect(model.launchAtLogin == .enabled)
        model.setLaunchAtLogin(false)
        #expect(model.launchAtLogin == .disabled)

        #expect(loginItem.requests == [true, false])
        #expect(model.launchAtLoginError == nil)
        #expect(loginItem.settingsOpened == 0)
    }

    @Test func approvalOpensTheLoginItemsSettings() {
        loginItem.stateAfterEnabling = .requiresApproval
        let model = makeModel()

        model.setLaunchAtLogin(true)

        #expect(model.launchAtLogin == .requiresApproval)
        #expect(loginItem.settingsOpened == 1)
        #expect(model.launchAtLoginError == nil)
    }

    @Test func failuresAreShownUntilAChangeWorks() {
        loginItem.error = TestError()
        let model = makeModel()

        model.setLaunchAtLogin(true)
        #expect(model.launchAtLogin == .disabled)
        #expect(model.launchAtLoginError == "Something went wrong")

        loginItem.error = nil
        model.setLaunchAtLogin(true)
        #expect(model.launchAtLogin == .enabled)
        #expect(model.launchAtLoginError == nil)
    }

    @Test func nothingIsRegisteredWhenUnavailable() {
        loginItem.state = .unavailable
        let model = makeModel()

        model.setLaunchAtLogin(true)

        #expect(loginItem.requests.isEmpty)
        #expect(model.launchAtLogin == .unavailable)
    }

    @Test func refreshPicksUpChangesMadeInSystemSettings() {
        let model = makeModel()
        loginItem.state = .enabled
        #expect(model.launchAtLogin == .disabled)

        model.refreshLaunchAtLogin()
        #expect(model.launchAtLogin == .enabled)

        model.openLoginItemsSettings()
        #expect(loginItem.settingsOpened == 1)
    }

    @Test func aChangeMadeElsewhereClearsAnOldError() {
        loginItem.error = TestError()
        let model = makeModel()
        model.setLaunchAtLogin(true)
        #expect(model.launchAtLoginError == "Something went wrong")

        model.refreshLaunchAtLogin()
        #expect(model.launchAtLoginError == "Something went wrong", "nothing changed yet")

        loginItem.state = .enabled
        model.refreshLaunchAtLogin()
        #expect(model.launchAtLogin == .enabled)
        #expect(model.launchAtLoginError == nil)
    }

    @Test func comingBackToTheSettingsWindowRefreshesLaunchAtLogin() {
        loginItem.stateAfterEnabling = .requiresApproval
        let model = makeModel()
        model.setLaunchAtLogin(true)
        #expect(model.launchAtLogin == .requiresApproval)

        // The user allows VitaPresence in System Settings, then switches back to the Settings window.
        loginItem.state = .enabled
        SettingsWindowController(model: model)
            .windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))

        #expect(model.launchAtLogin == .enabled)
    }
}

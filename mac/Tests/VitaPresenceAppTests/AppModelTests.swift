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
        commitDelay: Duration = .seconds(3600)
    ) -> AppModel {
        AppModel(
            store: store,
            controller: controller ?? self.controller,
            scanner: scanner,
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

    @Test func firstRunOpensSettingsAndConnectsOnceTheSettingsWork() async {
        let model = makeModel()

        #expect(model.launch() == .showSettings)
        #expect(model.isActive)
        #expect(await waitUntil { await controller.calls == [.start(PresenceSettings())] })

        // The controller waits for usable settings, so entering them is all it takes.
        model.choose(DiscoveredVita(ipAddress: "192.168.1.20", macAddress: nil, title: .liveArea))
        model.textBinding(for: \.clientID).wrappedValue = validSettings.clientID
        model.commitDraft()
        #expect(await waitUntil {
            await controller.calls == [
                .start(PresenceSettings()),
                .update(PresenceSettings(address: "192.168.1.20")),
                .update(validSettings),
            ]
        })
    }

    @Test func firstRunWithoutConnectOnLaunchOnlyOpensSettings() async {
        store.connectOnLaunch = false
        let model = makeModel()

        #expect(model.launch() == .showSettings)
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

        model.updateSettings { $0.clientID = "" }
        #expect(model.menuBarIcon == .attention)
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
        #expect(model.draft.issues == [.missingClientID])
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
        #expect(model.settings.address == "192.168.1.31")
        #expect(store.settings.address == "192.168.1.31")
        #expect(await waitUntil { await controller.calls == [.update(model.settings)] })
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

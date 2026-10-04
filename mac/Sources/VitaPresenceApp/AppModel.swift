import Combine
import Foundation
import os
import PresenceKit
import VitaKit

/// The parts of `PresenceController` the app uses, so tests can drive `AppModel` with a fake.
protocol PresenceControlling: Sendable {
    var snapshots: AsyncStream<PresenceSnapshot> { get }
    func start(with settings: PresenceSettings) async
    func updateSettings(_ settings: PresenceSettings) async
    func pollNow() async
    func stop() async
}

extension PresenceController: PresenceControlling {}

/// The app's state: the settings, the controller's latest snapshot, the network scan and launch at login.
/// The menu and the Settings window observe it, and every user action goes through it.
@MainActor
final class AppModel: ObservableObject {
    enum ScanState: Equatable {
        case idle
        case scanning
        case results([DiscoveredVita])
        case failed(String)
    }

    /// What `launch()` did.
    enum LaunchAction: Equatable {
        /// The settings aren't usable yet (first run), so the caller should open Settings. With
        /// `connectOnLaunch` on, the controller has started too, and begins polling once they are usable.
        case showSettings
        /// Started connecting, because `connectOnLaunch` is on.
        case connected
        /// Waiting for the user to connect.
        case none
    }

    /// The saved settings, which the controller has.
    @Published private(set) var settings: PresenceSettings
    /// What the Settings window shows: `settings` plus text edits that aren't committed yet. Typing changes
    /// only the draft; `commitDraft()` saves it and hands it to the controller.
    @Published private(set) var draft: PresenceSettings
    @Published private(set) var connectOnLaunch: Bool
    /// The controller's latest state.
    @Published private(set) var snapshot = PresenceSnapshot.idle
    /// `true` from `connect()` until `disconnect()`, so Connect/Disconnect reflects a click right away.
    @Published private(set) var isActive = false
    @Published private(set) var scanState = ScanState.idle
    /// `true` when the last scan failed because Local Network access is denied.
    @Published private(set) var scanNeedsLocalNetworkAccess = false
    @Published private(set) var launchAtLogin: LaunchAtLogin.State
    /// Why the last launch-at-login change didn't take effect, if it didn't.
    @Published private(set) var launchAtLoginError: String?

    private let store: SettingsStore
    private let scanner: @Sendable () async throws -> [DiscoveredVita]
    private let loginItem: LaunchAtLogin
    private let wakeNotifications: NotificationCenter
    private let commitDelay: Duration
    private let commands: AsyncStream<Command>.Continuation
    private let commandLoop: Task<Void, Never>
    private var snapshotLoop: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var systemEvents: SystemEventMonitor?
    /// Commits the draft once typing pauses.
    private var pendingCommit: Task<Void, Never>?

    /// - Parameters:
    ///   - wakeNotifications: Where the Mac's wake notifications arrive; tests pass their own center.
    ///   - commitDelay: How long typing has to pause before the draft is committed.
    init(
        store: SettingsStore = SettingsStore(),
        controller: any PresenceControlling = PresenceController(),
        scanner: @escaping @Sendable () async throws -> [DiscoveredVita] = { try await VitaScanner().scan() },
        loginItem: LaunchAtLogin = .mainApp,
        wakeNotifications: NotificationCenter = SystemEventMonitor.workspaceNotifications,
        commitDelay: Duration = .seconds(1)
    ) {
        self.store = store
        self.scanner = scanner
        self.loginItem = loginItem
        self.wakeNotifications = wakeNotifications
        self.commitDelay = commitDelay
        settings = store.settings
        draft = store.settings
        connectOnLaunch = store.connectOnLaunch
        launchAtLogin = loginItem.state()

        // Controller calls run one at a time, in the order they were made.
        let (commandStream, commands) = AsyncStream.makeStream(of: Command.self)
        self.commands = commands
        commandLoop = Task {
            for await command in commandStream {
                await command.perform(on: controller)
            }
        }
        snapshotLoop = Task { [weak self] in
            for await snapshot in controller.snapshots {
                self?.snapshot = snapshot
            }
        }
    }

    deinit {
        commands.finish()
        snapshotLoop?.cancel()
        pendingCommit?.cancel()
    }

    // MARK: Launch and quit

    /// Call once at launch: starts watching for wake and network changes, and connects if `connectOnLaunch`
    /// is on. With unusable settings (the first run) the controller waits until they are fixed, so entering
    /// them in Settings is enough to connect.
    func launch() -> LaunchAction {
        systemEvents = SystemEventMonitor(notificationCenter: wakeNotifications) { [weak self] in self?.pollNow() }
        if connectOnLaunch {
            connect()
        }
        guard settings.issues.isEmpty else { return .showSettings }
        return connectOnLaunch ? .connected : .none
    }

    /// Stops everything before the app quits: saves the draft, cancels a scan and stops the controller, which
    /// clears the presence. Waits at most `timeLimit` for that.
    func shutdown(timeLimit: Duration = .seconds(2)) async {
        commitDraft()
        systemEvents = nil
        scanTask?.cancel()
        isActive = false
        commands.yield(.stop)
        commands.finish()
        let commandLoop = commandLoop
        await withTimeLimit(timeLimit) { await commandLoop.value }
    }

    // MARK: Connection

    /// Starts the controller, with the draft committed first.
    func connect() {
        commitDraft()
        isActive = true
        commands.yield(.start(settings))
    }

    func disconnect() {
        isActive = false
        commands.yield(.stop)
    }

    func toggleConnection() {
        if isActive {
            disconnect()
        } else {
            connect()
        }
    }

    /// Polls right away, for example after the Mac wakes. Does nothing while disconnected.
    func pollNow() {
        guard isActive else { return }
        commands.yield(.pollNow)
    }

    /// `true` while polling fails because macOS denies Local Network access.
    var needsLocalNetworkAccess: Bool {
        if case .failing(.localNetworkDenied, _) = snapshot.vita { return true }
        return false
    }

    var menuBarIcon: MenuBarIcon {
        MenuBarIcon(snapshot: snapshot, hasSettingsIssues: !settings.issues.isEmpty)
    }

    // MARK: Settings

    /// Changes the settings right away: saves them and hands them to the controller, which applies them live.
    /// Draft edits that are still pending go along.
    func updateSettings(_ mutate: (inout PresenceSettings) -> Void) {
        mutate(&draft)
        commitDraft()
    }

    /// Changes the draft while the user types. It is committed once typing pauses for `commitDelay`, or
    /// earlier by `commitDraft()`.
    func editDraft(_ mutate: (inout PresenceSettings) -> Void) {
        mutate(&draft)
        pendingCommit?.cancel()
        pendingCommit = Task { [weak self, commitDelay] in
            try? await Task.sleep(for: commitDelay)
            guard !Task.isCancelled else { return }
            self?.commitDraft()
        }
    }

    /// Saves the draft and hands it to the controller if it differs from `settings`. Besides after a pause in
    /// typing, this happens on Return, when the Settings window closes, before connecting and before quitting.
    func commitDraft() {
        pendingCommit?.cancel()
        pendingCommit = nil
        guard draft != settings else { return }
        settings = draft
        store.settings = draft
        commands.yield(.update(draft))
    }

    func setConnectOnLaunch(_ enabled: Bool) {
        connectOnLaunch = enabled
        store.connectOnLaunch = enabled
    }

    // MARK: Finding the Vita

    /// Looks for Vitas on the local network ("Find on Network").
    func scan() {
        guard scanState != .scanning else { return }
        scanState = .scanning
        scanNeedsLocalNetworkAccess = false
        scanTask = Task { [scanner] in
            do {
                scanState = .results(try await scanner())
            } catch is CancellationError {
                scanState = .idle
            } catch let error as VitaConnectionError {
                scanState = .failed(error.userMessage)
                scanNeedsLocalNetworkAccess = error == .localNetworkDenied
            } catch {
                scanState = .failed(error.localizedDescription)
            }
        }
    }

    /// Uses a scan result by filling in its IP address. Its MAC address isn't used, because macOS hides the
    /// ARP cache from most apps, so a MAC address can't be resolved reliably.
    func choose(_ vita: DiscoveredVita) {
        updateSettings { $0.address = vita.ipAddress }
    }

    // MARK: Launch at login

    /// Re-reads the login item, which the user can also change in System Settings. An error from an earlier
    /// change no longer applies once the state has changed.
    func refreshLaunchAtLogin() {
        let state = loginItem.state()
        if state != launchAtLogin {
            launchAtLoginError = nil
        }
        launchAtLogin = state
    }

    /// Turns launch at login on or off; only ever called for an explicit user action. When macOS needs the
    /// user's approval first, opens the Login Items settings.
    func setLaunchAtLogin(_ enabled: Bool) {
        guard launchAtLogin != .unavailable else { return }
        var failure: (any Error)?
        do {
            try loginItem.setEnabled(enabled)
        } catch {
            failure = error
        }
        refreshLaunchAtLogin()
        switch (enabled, launchAtLogin) {
        case (true, .enabled), (false, .disabled):
            launchAtLoginError = nil
        case (true, .requiresApproval):
            launchAtLoginError = nil
            loginItem.openSystemSettingsLoginItems()
        default:
            launchAtLoginError = failure?.localizedDescription ?? "macOS didn't change the login item."
        }
    }

    func openLoginItemsSettings() {
        loginItem.openSystemSettingsLoginItems()
    }
}

/// A queued call to the controller.
private enum Command: Sendable {
    case start(PresenceSettings)
    case update(PresenceSettings)
    case pollNow
    case stop

    func perform(on controller: any PresenceControlling) async {
        switch self {
        case .start(let settings): await controller.start(with: settings)
        case .update(let settings): await controller.updateSettings(settings)
        case .pollNow: await controller.pollNow()
        case .stop: await controller.stop()
        }
    }
}

/// Waits for `operation`, but no longer than `limit`. A slower operation keeps running in the background.
func withTimeLimit(_ limit: Duration, _ operation: @escaping @Sendable () async -> Void) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let resume: @Sendable () -> Void = {
            let isFirst = resumed.withLock { resumed in
                defer { resumed = true }
                return !resumed
            }
            if isFirst {
                continuation.resume()
            }
        }
        let timer = Task {
            try? await Task.sleep(for: limit)
            resume()
        }
        Task {
            await operation()
            resume()
            timer.cancel()
        }
    }
}

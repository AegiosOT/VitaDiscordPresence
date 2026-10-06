import ArtworkKit
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
    func rememberVita(host: String?, macAddress: MACAddress?) async
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
        /// The saved settings can't be used (an invalid address or application ID), so the caller should open
        /// Settings. With `connectOnLaunch` on, the controller has started too, and begins polling once they are
        /// fixed.
        case showSettings
        /// Started connecting, because `connectOnLaunch` is on. The defaults are usable, so the first launch
        /// does this too.
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
    /// Whether the Settings window shows the field for a Discord application of the user's own. On at launch
    /// when one is set; turning it off goes back to the built-in application.
    @Published private(set) var usesOwnDiscordApplication: Bool
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
    /// Consoles this Mac has connected to. The selected one is found automatically.
    @Published private(set) var profiles: [VitaProfile] = []
    /// Which profile to connect to. `nil` when none is saved.
    @Published private(set) var selectedProfileID: UUID?

    private let store: SettingsStore
    private let scanner: @Sendable () async throws -> [DiscoveredVita]
    private let macLookup: @Sendable (String) -> MACAddress?
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
    ///   - makeController: Builds the controller, given the Vita to find first (`nil` host when unknown).
    ///     Tests pass a fake.
    ///   - macLookup: The MAC address of a host that just answered, from the ARP cache. Tests replace it.
    ///   - wakeNotifications: Where the Mac's wake notifications arrive; tests pass their own center.
    ///   - commitDelay: How long typing has to pause before the draft is committed.
    init(
        store: SettingsStore = SettingsStore(),
        makeController: (_ remembered: RememberedVita) -> any PresenceControlling = AppModel.makePresenceController,
        scanner: @escaping @Sendable () async throws -> [DiscoveredVita] = { try await VitaScanner().scan() },
        macLookup: @escaping @Sendable (String) -> MACAddress? = { ARPTable.macAddress(forIPAddress: $0) },
        loginItem: LaunchAtLogin = .mainApp,
        wakeNotifications: NotificationCenter = SystemEventMonitor.workspaceNotifications,
        commitDelay: Duration = .seconds(1)
    ) {
        self.store = store
        self.scanner = scanner
        self.macLookup = macLookup
        self.loginItem = loginItem
        self.wakeNotifications = wakeNotifications
        self.commitDelay = commitDelay
        store.migrateProfilesIfNeeded()
        let saved = store.settings
        settings = saved
        draft = saved
        connectOnLaunch = store.connectOnLaunch
        usesOwnDiscordApplication = saved.usesCustomClientID
        launchAtLogin = loginItem.state()
        profiles = store.profiles
        selectedProfileID = store.selectedProfileID
        let controller = makeController(store.rememberedVita)

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
                self?.receive(snapshot)
            }
        }
    }

    deinit {
        commands.finish()
        snapshotLoop?.cancel()
        pendingCommit?.cancel()
    }

    /// The real controller: it finds the Vita automatically, polling the remembered host before it scans the
    /// network, and looks up game artwork, caching it in the user's Caches folder.
    nonisolated static func makePresenceController(remembered: RememberedVita) -> any PresenceControlling {
        PresenceController(
            resolver: VitaResolver(knownHost: remembered.host, knownMAC: remembered.macAddress),
            discord: DiscordHelperClient(),
            artwork: ArtworkResolver()
        )
    }

    // MARK: Launch and quit

    /// Call once at launch: starts watching for wake and network changes, and connects if `connectOnLaunch`
    /// is on. With unusable settings the controller waits until they are fixed, so fixing them in Settings is
    /// enough to connect.
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

    /// What the PS Vita section says while the Vita is found automatically: where it answered ("Found at
    /// 192.168.1.20"), that it's being looked for, why it can't be found, or where it answered last while it
    /// doesn't answer. `nil` while disconnected, and while an address is typed in.
    var discoveryStatus: String? {
        guard settings.vitaAddress == .automatic, draft.vitaAddress == .automatic else { return nil }
        switch snapshot.vita {
        case .idle, .misconfigured: return nil
        case .connected: return snapshot.host.map { "Found at \($0)" }
        case .failing(.unresolvedAddress(let message), _): return message
        case .failing(.severalVitas, _), .failing(.noLocalNetwork, _): return snapshot.vita.summary
        case .failing: return snapshot.host.map { "Last found at \($0)" } ?? VitaStatus.resolving.summary
        case .resolving, .connecting: return VitaStatus.resolving.summary
        }
    }

    /// `true` when `vita` is the Vita in use: the selected profile, the one at the address typed in, or the
    /// one being polled. Find on Network marks it instead of offering to use it.
    func isInUse(_ vita: DiscoveredVita) -> Bool {
        if draft.vitaAddress == .automatic, let selected = selectedProfile {
            if let mac = vita.macAddress?.description, selected.macAddress == mac { return true }
            if selected.lastAddress == vita.ipAddress { return true }
        }
        guard let address = draft.vitaAddress else { return false }
        switch address {
        case .ipv4(let host): return host == vita.ipAddress
        case .mac(let mac) where vita.macAddress == mac: return true
        case .automatic, .mac: return address == settings.vitaAddress && snapshot.host == vita.ipAddress
        }
    }

    /// The profile automatic discovery connects to.
    var selectedProfile: VitaProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    /// The picture friends see next to the game when it is a web image (the game artwork, or a custom image
    /// URL). The Settings window shows it as a thumbnail. `nil` for an asset key, which only Discord can show.
    var largeImageURL: URL? {
        guard let image = snapshot.publishedActivity?.assets?.largeImage,
              image.lowercased().hasPrefix("https://")
        else { return nil }
        return URL(string: image)
    }

    /// A host automatic discovery should try first next time. Loopback and this Mac's own addresses are skipped:
    /// a mock or a mistaken scan must not become the remembered Vita.
    private static func isRememberableHost(_ host: String) -> Bool {
        if host == "127.0.0.1" || host.hasPrefix("127.") { return false }
        return !LocalNetwork.interfaces().contains { $0.address == host }
    }

    /// Takes in the controller's latest state. A Vita found automatically is saved as the selected profile, so
    /// the next launch polls it, and a later address change stays on that same console.
    private func receive(_ snapshot: PresenceSnapshot) {
        self.snapshot = snapshot
        guard snapshot.vita == .connected, let host = snapshot.host, Self.isRememberableHost(host),
              settings.vitaAddress == .automatic
        else { return }
        let mac = macLookup(host)?.description
        if let selected = selectedProfile {
            var updated = selected
            let identityChanged = updated.lastAddress != host || (mac != nil && updated.macAddress != mac)
            updated.lastAddress = host
            updated.lastSeen = Date()
            if let mac { updated.macAddress = mac }
            replace(updated)
            if identityChanged { remember(updated) }
            return
        }
        let profile = VitaProfile(
            id: UUID(),
            name: VitaProfile.defaultName,
            lastAddress: host,
            macAddress: mac,
            lastSeen: Date()
        )
        profiles.append(profile)
        store.profiles = profiles
        selectedProfileID = profile.id
        store.selectedProfileID = profile.id
        store.lastVitaHost = host
        if mac != nil { remember(profile) }
    }

    /// Saves `profile` in place and keeps `lastVitaHost` on the selected console.
    private func replace(_ profile: VitaProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        store.profiles = profiles
        if profile.id == selectedProfileID {
            store.lastVitaHost = profile.lastAddress
        }
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

    /// Shows or hides the field for a Discord application of the user's own. Hiding it clears the application
    /// ID, which goes back to the built-in application.
    func setUsesOwnDiscordApplication(_ enabled: Bool) {
        usesOwnDiscordApplication = enabled
        if !enabled {
            updateSettings {
                $0.clientID = ""
                // An asset name belongs to the application that was just turned off. An https URL still works.
                let image = $0.largeImageKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if !image.lowercased().hasPrefix("https://") {
                    $0.largeImageKey = ""
                }
            }
        }
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

    /// Uses a scan result: saves it as a profile (or updates the one with the same MAC address) and connects.
    /// The settings address stays automatic, so a later IP address change can still be followed. A host that
    /// must not be remembered, such as loopback, is used as a typed address instead.
    func choose(_ vita: DiscoveredVita) {
        guard Self.isRememberableHost(vita.ipAddress) else {
            updateSettings { $0.address = vita.ipAddress }
            return
        }
        let mac = vita.macAddress?.description
        if let existing = profiles.first(where: { profile in
            if let mac, profile.macAddress == mac { return true }
            return profile.macAddress == nil && profile.lastAddress == vita.ipAddress
        }) {
            var updated = existing
            updated.lastAddress = vita.ipAddress
            updated.lastSeen = Date()
            if let mac { updated.macAddress = mac }
            replace(updated)
            selectProfile(updated.id)
            return
        }
        let name = profiles.isEmpty ? VitaProfile.defaultName : "\(VitaProfile.defaultName) \(profiles.count + 1)"
        let profile = VitaProfile(
            id: UUID(),
            name: name,
            lastAddress: vita.ipAddress,
            macAddress: mac,
            lastSeen: Date()
        )
        profiles.append(profile)
        store.profiles = profiles
        selectProfile(profile.id)
    }

    /// Connects to a saved console. A typed address is cleared so discovery can follow that console's MAC
    /// address when its IP address changes.
    func selectProfile(_ id: UUID) {
        guard apply(id) else { return }
        if isActive {
            pollNow()
        } else {
            connect()
        }
    }

    /// Forgets a saved console. When it was the selected one, the next saved console is used, or discovery
    /// starts with no remembered Vita. Removing a console does not start a connection on its own.
    func removeProfile(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        store.profiles = profiles
        guard selectedProfileID == id else { return }
        if let next = profiles.first {
            _ = apply(next.id)
            if isActive { pollNow() }
        } else {
            selectedProfileID = nil
            store.selectedProfileID = nil
            store.lastVitaHost = nil
            commands.yield(.remember(host: nil, macAddress: nil))
            if isActive { pollNow() }
        }
    }

    /// Points discovery at `id` and clears a typed address. The remembered host is sent before the address
    /// change, so the poll that follows already looks for this console. Returns whether `id` is a profile.
    @discardableResult
    private func apply(_ id: UUID) -> Bool {
        guard let profile = profiles.first(where: { $0.id == id }) else { return false }
        selectedProfileID = id
        store.selectedProfileID = id
        store.lastVitaHost = profile.lastAddress
        remember(profile)
        if settings.address != "" || draft.address != "" {
            updateSettings { $0.address = "" }
        }
        return true
    }

    /// Changes the label of a saved console. A blank name is shown as "PS Vita".
    func renameProfile(_ id: UUID, to name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = name
        store.profiles = profiles
    }

    /// Tells the controller which console to find, using the profile saved just now.
    private func remember(_ profile: VitaProfile) {
        commands.yield(.remember(host: profile.lastAddress, macAddress: profile.mac))
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
    case remember(host: String?, macAddress: MACAddress?)
    case pollNow
    case stop

    func perform(on controller: any PresenceControlling) async {
        switch self {
        case .start(let settings): await controller.start(with: settings)
        case .update(let settings): await controller.updateSettings(settings)
        case .remember(let host, let macAddress): await controller.rememberVita(host: host, macAddress: macAddress)
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

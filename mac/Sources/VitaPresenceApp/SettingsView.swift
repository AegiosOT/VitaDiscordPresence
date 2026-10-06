import AppKit
import PresenceKit
import SwiftUI
import VitaKit

/// The Settings window's content. Every control reads and writes `AppModel`. Text edits are saved and applied
/// once typing pauses or on Return, everything else right away.
struct SettingsView: View {
    @ObservedObject var model: AppModel

    private static let developerPortal = URL(string: "https://discord.com/developers/applications")!
    private static let motion = Animation.spring(response: 0.35, dampingFraction: 0.86)

    var body: some View {
        ScrollView {
            GlassGroup {
                VStack(alignment: .leading, spacing: 16) {
                    statusCard
                    HStack(alignment: .top, spacing: 16) {
                        consoleColumn
                            .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 20) {
                            presenceColumn
                            generalColumn
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 680, minHeight: 460)
    }

    // MARK: Columns

    private var consoleColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Console", symbol: "gamecontroller")
            Group {
                if model.profiles.isEmpty {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No Vita saved yet")
                                .font(.headline)
                            Text("Find it on the network. VitaPresence reconnects to it next time, including after its IP address changes.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .transition(Self.appear)
                } else {
                    ForEach(model.profiles) { profile in
                        profileRow(profile)
                            .transition(Self.appear)
                    }
                }
            }
            .animation(Self.motion, value: model.profiles.map(\.id))
            .animation(Self.motion, value: model.selectedProfileID)
            findControls
            scanResults
            DisclosureGroup("Enter an address") {
                TextField(
                    "IP or MAC address",
                    text: model.textBinding(for: \.address),
                    prompt: Text("Automatic")
                )
                .padding(.top, 4)
                issues(.invalidAddress)
            }
        }
        .animation(Self.motion, value: model.scanState)
    }

    private var presenceColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Presence", symbol: "dot.radiowaves.left.and.right")
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Show game artwork", isOn: model.binding(for: \.showGameArtwork))
                    Toggle("Show the LiveArea", isOn: model.binding(for: \.showLiveArea))
                    Toggle("Show elapsed time", isOn: model.binding(for: \.showElapsedTime))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup("More") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField(
                        "Custom image (replaces game artwork)",
                        text: model.textBinding(for: \.largeImageKey),
                        prompt: Text("Asset key or https URL")
                    )
                    if let warning = model.draft.largeImageWarning {
                        Text(warning)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .transition(Self.appear)
                    }
                    TextField("State text", text: model.textBinding(for: \.stateText), prompt: Text("Optional"))
                    Toggle("Use my own Discord application", isOn: model.ownDiscordApplicationBinding)
                    if model.usesOwnDiscordApplication {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField(
                                "Application ID",
                                text: model.textBinding(for: \.clientID),
                                prompt: Text("Built-in")
                            )
                            issues(.invalidClientID)
                            Link("Open the Discord Developer Portal", destination: Self.developerPortal)
                        }
                        .transition(Self.appear)
                    }
                }
                .padding(.top, 8)
                .animation(Self.motion, value: model.draft.largeImageWarning)
                .animation(Self.motion, value: model.usesOwnDiscordApplication)
            }
        }
    }

    private var generalColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("General", symbol: "gearshape")
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Connect automatically at launch", isOn: model.connectOnLaunchBinding)
                    Toggle("Launch at login", isOn: model.launchAtLoginBinding)
                        .disabled(model.launchAtLogin == .unavailable)
                    launchAtLoginStatus
                    LabeledContent("Check every") {
                        HStack(spacing: 6) {
                            TextField("Poll interval", value: model.pollIntervalBinding, format: .number)
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 56)
                            Stepper(
                                "Poll interval",
                                value: model.pollIntervalBinding,
                                in: PresenceSettings.pollIntervalRange,
                                step: 1
                            )
                            .labelsHidden()
                            Text("seconds")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func sectionHeader(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    // MARK: Console parts

    private func profileRow(_ profile: VitaProfile) -> some View {
        let selected = profile.id == model.selectedProfileID
        return GlassCard(interactive: true) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Name", text: model.profileNameBinding(profile.id), prompt: Text(VitaProfile.defaultName))
                        .textFieldStyle(.plain)
                        .font(.headline)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(details(of: profile))
                        if selected, let status = model.discoveryStatus {
                            Text(status)
                                .transition(Self.appear)
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard profile.id != model.selectedProfileID else { return }
                        model.selectProfile(profile.id)
                    }
                }
                .animation(Self.motion, value: model.discoveryStatus)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("In use")
                        .replacingSymbol()
                        .transition(.scale.combined(with: .opacity))
                }
                Button("Remove") { model.removeProfile(profile.id) }
            }
        }
    }

    private var findControls: some View {
        HStack(spacing: 8) {
            ProminentButton(title: "Find on Network", isDisabled: model.scanState == .scanning) {
                model.scan()
            }
            if model.scanState == .scanning {
                HStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                        .pulsingSymbol()
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching…")
                        .foregroundStyle(.secondary)
                }
                .transition(Self.appear)
            }
        }
    }

    @ViewBuilder
    private var scanResults: some View {
        switch model.scanState {
        case .idle, .scanning:
            EmptyView()
        case .results(let vitas) where vitas.isEmpty:
            Text("No Vita answered. Check that it's awake, on the same network, and running the VitaPresence plugin.")
                .foregroundStyle(.secondary)
                .transition(Self.appear)
        case .results(let vitas):
            ForEach(vitas) { vita in
                GlassCard(interactive: true) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(vita.ipAddress)
                            Text(details(of: vita))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.isInUse(vita) {
                            Text("In use")
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Use") { model.choose(vita) }
                        }
                    }
                }
                .transition(Self.appear)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .foregroundStyle(.red)
                if model.scanNeedsLocalNetworkAccess {
                    Button("Allow Local Network Access…") { SystemSettings.openLocalNetworkPrivacy() }
                }
            }
            .transition(Self.appear)
        }
    }

    // MARK: Shared parts

    @ViewBuilder
    private var launchAtLoginStatus: some View {
        switch model.launchAtLogin {
        case .requiresApproval:
            LabeledContent("Allow VitaPresence in System Settings to finish turning this on.") {
                Button("Open Login Items Settings") { model.openLoginItemsSettings() }
            }
        case .unavailable:
            Text("Available when VitaPresence runs as an app from your Applications folder.")
                .foregroundStyle(.secondary)
        case .enabled, .disabled:
            EmptyView()
        }
        if let error = model.launchAtLoginError {
            Text(error)
                .foregroundStyle(.red)
        }
    }

    /// Changes when what is showing changes, and stays put while only the elapsed clock ticks.
    private var presenceIdentity: String {
        let title = model.snapshot.title?.titleID ?? ""
        return "\(model.snapshot.isRunning)-\(title)-\(String(describing: model.snapshot.vita))-\(String(describing: model.snapshot.discord))"
    }

    private var statusCard: some View {
        GlassCard {
            HStack(spacing: 12) {
                if let image = model.largeImageURL {
                    thumbnail(of: image)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
                // Redrawn every second, so the elapsed time keeps counting between polls. The block itself
                // only moves when the presence changes, not on each tick of the clock.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let lines = StatusText.lines(for: model.snapshot, now: context.date)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                        }
                    }
                }
                .id(presenceIdentity)
                .transition(.opacity)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                if model.needsLocalNetworkAccess {
                    Button("Allow Local Network Access…") { SystemSettings.openLocalNetworkPrivacy() }
                        .transition(Self.appear)
                }
                ProminentButton(title: model.isActive ? "Disconnect" : "Connect") {
                    model.toggleConnection()
                }
            }
            .animation(Self.motion, value: model.largeImageURL)
            .animation(Self.motion, value: model.snapshot.title)
            .animation(Self.motion, value: model.snapshot.vita)
            .animation(Self.motion, value: model.snapshot.discord)
            .animation(Self.motion, value: model.isActive)
            .animation(Self.motion, value: model.needsLocalNetworkAccess)
        }
    }

    private static var appear: AnyTransition {
        .move(edge: .top).combined(with: .opacity)
    }

    /// The large image friends see next to the game, cropped to a square. Loaded without cookies or a disk
    /// cache, so a store picture's tracking cookie is not stored or sent back.
    private func thumbnail(of url: URL) -> some View {
        CookieFreeThumbnail(url: url)
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Inline error messages for the issues among `relevant` in what is typed.
    private func issues(_ relevant: PresenceSettings.Issue...) -> some View {
        ForEach(model.draft.issues.filter(relevant.contains), id: \.message) { issue in
            Text(issue.message)
                .font(.callout)
                .foregroundStyle(.red)
        }
    }

    private func details(of profile: VitaProfile) -> String {
        if let mac = profile.macAddress {
            return "\(profile.lastAddress) · \(mac)"
        }
        return profile.lastAddress
    }

    private func details(of vita: DiscoveredVita) -> String {
        let running = vita.title.isLiveArea ? "In the LiveArea" : vita.title.displayName
        guard let mac = vita.macAddress else { return running }
        return "\(running) · \(mac)"
    }
}

private extension View {
    /// Pulses a symbol for as long as it is on screen. Before macOS 14 the symbol stays still.
    @ViewBuilder
    func pulsingSymbol() -> some View {
        if #available(macOS 14, *) {
            self.symbolEffect(.pulse, options: .repeating)
        } else {
            self
        }
    }

    /// Replaces a symbol with the next one. Before macOS 14 the symbol changes in place.
    @ViewBuilder
    func replacingSymbol() -> some View {
        if #available(macOS 14, *) {
            self.contentTransition(.symbolEffect(.replace))
        } else {
            self
        }
    }
}

/// Loads `url` with an ephemeral session that stores no cookies and no cache.
private struct CookieFreeThumbnail: NSViewRepresentable {
    var url: URL

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setAccessibilityLabel("Image shown on Discord")
        context.coordinator.load(url, into: view)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        context.coordinator.load(url, into: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var loaded: URL?

        func load(_ url: URL, into view: NSImageView) {
            guard loaded != url else { return }
            loaded = url
            view.image = nil
            Task {
                let image = await Self.fetch(url)
                guard self.loaded == url else { return }
                view.image = image
            }
        }

        private static func fetch(_ url: URL) async -> NSImage? {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.httpShouldSetCookies = false
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            guard let (data, response) = try? await session.data(from: url),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else { return nil }
            return NSImage(data: data)
        }
    }
}

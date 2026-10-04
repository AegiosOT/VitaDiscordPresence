import PresenceKit
import SwiftUI
import VitaKit

/// The Settings window's content. It keeps no state of its own: every control reads and writes `AppModel`.
/// Text edits are saved and applied once typing pauses or on Return, everything else right away.
struct SettingsView: View {
    @ObservedObject var model: AppModel

    private static let developerPortal = URL(string: "https://discord.com/developers/applications")!

    var body: some View {
        VStack(spacing: 0) {
            Form {
                vitaSection
                discordSection
                presenceSection
                generalSection
            }
            .formStyle(.grouped)
            .onSubmit { model.commitDraft() }
            Divider()
            footer
        }
        .frame(minWidth: 460, minHeight: 420)
    }

    // MARK: Sections

    private var vitaSection: some View {
        Section {
            TextField("IP or MAC address", text: model.textBinding(for: \.address), prompt: Text("192.168.1.20"))
            issues(.missingAddress, .invalidAddress)
            HStack(spacing: 8) {
                Button("Find on Network") { model.scan() }
                    .disabled(model.scanState == .scanning)
                if model.scanState == .scanning {
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching…")
                        .foregroundStyle(.secondary)
                }
            }
            scanResults
        } header: {
            Text("PS Vita")
        } footer: {
            Text("Enter the IP address shown in your Vita's Wi-Fi settings, or use Find on Network. A MAC address also works, but macOS can't always look it up. The Vita must be awake, on the same network as this Mac, and running the VitaPresence plugin.")
        }
    }

    private var discordSection: some View {
        Section {
            TextField(
                "Application ID",
                text: model.textBinding(for: \.clientID),
                prompt: Text("From the Developer Portal")
            )
            issues(.missingClientID, .invalidClientID)
            Link("Open the Discord Developer Portal", destination: Self.developerPortal)
        } header: {
            Text("Discord")
        } footer: {
            Text("Create an application in the Developer Portal and paste its Application ID here. Discord shows the application's name after “Playing”, so name it “PS Vita”.")
        }
    }

    private var presenceSection: some View {
        Section {
            TextField("State text", text: model.textBinding(for: \.stateText), prompt: Text("Optional"))
            TextField(
                "Large image",
                text: model.textBinding(for: \.largeImageKey),
                prompt: Text("Asset key or https URL")
            )
            Toggle("Show elapsed time", isOn: model.binding(for: \.showElapsedTime))
            Toggle("Show the LiveArea", isOn: model.binding(for: \.showLiveArea))
        } header: {
            Text("Presence")
        } footer: {
            Text("State text is an optional second line under the game. The large image is an asset key from your Discord application or an https image URL. With “Show the LiveArea” off, your presence is hidden while the Vita is on its home screen.")
        }
    }

    private var generalSection: some View {
        Section {
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
            Toggle("Connect automatically at launch", isOn: model.connectOnLaunchBinding)
            Toggle("Launch at login", isOn: model.launchAtLoginBinding)
                .disabled(model.launchAtLogin == .unavailable)
            launchAtLoginStatus
        } header: {
            Text("General")
        }
    }

    // MARK: Parts

    @ViewBuilder
    private var scanResults: some View {
        switch model.scanState {
        case .idle, .scanning:
            EmptyView()
        case .results(let vitas) where vitas.isEmpty:
            Text("No Vita answered. Check that it's awake, on the same network, and running the VitaPresence plugin.")
                .foregroundStyle(.secondary)
        case .results(let vitas):
            ForEach(vitas) { vita in
                LabeledContent {
                    if vita.ipAddress == model.draft.address.trimmingCharacters(in: .whitespacesAndNewlines) {
                        Text("In use")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Use") { model.choose(vita) }
                    }
                } label: {
                    Text(vita.ipAddress)
                    Text(details(of: vita))
                }
            }
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
            if model.scanNeedsLocalNetworkAccess {
                Button("Allow Local Network Access…") { SystemSettings.openLocalNetworkPrivacy() }
            }
        }
    }

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

    private var footer: some View {
        HStack(spacing: 12) {
            // Redrawn every second, so the elapsed time keeps counting between polls.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(StatusText.lines(for: model.snapshot, now: context.date), id: \.self) { line in
                        Text(line)
                    }
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.needsLocalNetworkAccess {
                Button("Allow Local Network Access…") { SystemSettings.openLocalNetworkPrivacy() }
            }
            Button(model.isActive ? "Disconnect" : "Connect") { model.toggleConnection() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// Inline messages for the issues among `relevant` of what is typed. A missing value is a hint, an
    /// invalid one an error.
    private func issues(_ relevant: PresenceSettings.Issue...) -> some View {
        ForEach(model.draft.issues.filter(relevant.contains), id: \.message) { issue in
            Text(issue.message)
                .font(.callout)
                .foregroundStyle(issue == .invalidAddress || issue == .invalidClientID ? Color.red : Color.secondary)
        }
    }

    private func details(of vita: DiscoveredVita) -> String {
        let running = vita.title.isLiveArea ? "In the LiveArea" : vita.title.displayName
        guard let mac = vita.macAddress else { return running }
        return "\(running) · \(mac)"
    }
}

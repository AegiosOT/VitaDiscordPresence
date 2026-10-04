import AppKit
import SwiftUI

/// The menu that opens from the menu bar icon.
struct MenuContent: View {
    @ObservedObject var model: AppModel
    let openSettings: @MainActor () -> Void

    var body: some View {
        // The elapsed time is as of SwiftUI's last evaluation of this view; every successful poll causes one.
        ForEach(StatusText.lines(for: model.snapshot, now: Date()), id: \.self) { line in
            Text(line)
        }
        if model.needsLocalNetworkAccess {
            Button("Allow Local Network Access…") { SystemSettings.openLocalNetworkPrivacy() }
        }
        Divider()
        Button(model.isActive ? "Disconnect" : "Connect") { model.toggleConnection() }
        Button("Settings…") { openSettings() }
            .keyboardShortcut(",")
        Toggle("Launch at Login", isOn: model.launchAtLoginBinding)
            .disabled(model.launchAtLogin == .unavailable)
        Divider()
        Button("Quit VitaPresence") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

import AppKit

/// Opens the System Settings panes the app sends people to.
@MainActor
enum SystemSettings {
    private static let localNetworkPrivacy =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!
    private static let privacyAndSecurity = URL(string: "x-apple.systempreferences:com.apple.preference.security")!

    /// Opens Privacy & Security › Local Network, falling back to Privacy & Security.
    static func openLocalNetworkPrivacy() {
        if !NSWorkspace.shared.open(localNetworkPrivacy) {
            NSWorkspace.shared.open(privacyAndSecurity)
        }
    }
}

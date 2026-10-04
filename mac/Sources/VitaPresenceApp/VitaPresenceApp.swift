import SwiftUI

/// VitaPresence lives in the menu bar and shows the game running on a PS Vita as Discord Rich Presence.
@main
struct VitaPresenceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: appDelegate.model, openSettings: appDelegate.showSettings)
        } label: {
            MenuBarLabel(model: appDelegate.model)
        }
        .menuBarExtraStyle(.menu)
    }
}

import AppKit

/// Owns the app's single `AppModel` and the Settings window, and handles launch and quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private lazy var settingsWindow = SettingsWindowController(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        if model.launch() == .showSettings {
            showSettings()
        }
    }

    func showSettings() {
        settingsWindow.show()
    }

    /// Quitting first stops the controller, so the presence is cleared and Discord's connection is closed
    /// cleanly. `shutdown()` gives up after about 2 seconds, so a hung connection can't block quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Closing the Settings window must not quit a menu bar app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

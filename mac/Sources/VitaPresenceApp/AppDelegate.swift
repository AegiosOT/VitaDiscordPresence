import AppKit
import Combine

/// Owns the app's single `AppModel` and the Settings window, and handles launch and quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private lazy var settingsWindow = SettingsWindowController(model: model)
    private var iconObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if model.launch() == .showSettings {
            showSettings()
        }
        // SwiftUI's menu bar label drops a bitmap. The status item will show the Vita once the picture
        // is assigned to the button itself.
        applyMenuBarIcon()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            self.applyMenuBarIcon()
        }
        iconObserver = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.applyMenuBarIcon() }
        }
    }

    private func applyMenuBarIcon() {
        guard let button = Self.statusButton() else { return }
        let image: NSImage?
        if model.menuBarIcon == .attention {
            image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "VitaPresence")
        } else {
            image = MenuBarArtwork.cached
        }
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
    }

    private static func statusButton() -> NSStatusBarButton? {
        for window in NSApp.windows {
            if let button = button(in: window.contentView) { return button }
        }
        return nil
    }

    private static func button(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = button(in: subview) { return button }
        }
        return nil
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

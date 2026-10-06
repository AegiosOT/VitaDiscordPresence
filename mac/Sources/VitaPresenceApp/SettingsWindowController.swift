import AppKit
import SwiftUI

/// The Settings window: one `EditingWindow` hosting `SettingsView`, created on first use and reused.
///
/// A menu bar app runs as an accessory without a Dock icon, and macOS doesn't reliably give an accessory's
/// windows keyboard focus. While the window is open the app becomes a regular app, so its text fields can be
/// focused, and it goes back to being an accessory when the window closes.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        model.refreshLaunchAtLogin()
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Coming back to the window, for example from System Settings after approving the login item, shows
    /// the login item's current state.
    func windowDidBecomeKey(_ notification: Notification) {
        model.refreshLaunchAtLogin()
    }

    func windowWillClose(_ notification: Notification) {
        model.commitDraft()
        NSApp.setActivationPolicy(.accessory)
    }

    private func makeWindow() -> NSWindow {
        let content = NSHostingController(rootView: SettingsView(model: model))
        // SwiftUI only enforces the minimum size; the window keeps the size set here (or the saved one).
        content.sizingOptions = [.minSize]
        let window = EditingWindow(contentViewController: content)
        window.title = "VitaPresence Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 760, height: 560))
        window.center()
        window.setFrameAutosaveName("Settings")
        window.delegate = self
        return window
    }
}

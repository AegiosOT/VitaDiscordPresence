import AppKit
import Foundation
import Network
import os
import ServiceManagement
import Testing
@testable import VitaPresenceApp

struct LaunchAtLoginStateTests {
    let installed = "/Applications/VitaPresence.app"

    @Test func mapsTheServiceStatus() {
        #expect(LaunchAtLogin.State(.enabled, bundlePath: installed) == .enabled)
        #expect(LaunchAtLogin.State(.requiresApproval, bundlePath: installed) == .requiresApproval)
        #expect(LaunchAtLogin.State(.notRegistered, bundlePath: installed) == .disabled)
        #expect(LaunchAtLogin.State(.notFound, bundlePath: installed) == .disabled)
    }

    @Test func unavailableOutsideAnAppBundle() {
        #expect(LaunchAtLogin.State(.enabled, bundlePath: "/usr/local/bin") == .unavailable)
        #expect(LaunchAtLogin.State(.notFound, bundlePath: "/Users/me/VitaPresence/.build/debug") == .unavailable)
    }

    @Test func unavailableWhileTranslocated() {
        let translocated = "/private/var/folders/ab/xyz/T/AppTranslocation/0F1E2D3C/d/VitaPresence.app"

        #expect(LaunchAtLogin.State(.notRegistered, bundlePath: translocated) == .unavailable)
    }

    @Test func theTestRunnerIsNoAppBundle() {
        #expect(LaunchAtLogin.mainApp.state() == .unavailable)
    }
}

struct SystemEventMonitorTests {
    @Test func onlyATransitionToSatisfiedCounts() {
        #expect(SystemEventMonitor.becameSatisfied(from: .unsatisfied, to: .satisfied))
        #expect(SystemEventMonitor.becameSatisfied(from: .requiresConnection, to: .satisfied))
        #expect(!SystemEventMonitor.becameSatisfied(from: .satisfied, to: .satisfied))
        #expect(!SystemEventMonitor.becameSatisfied(from: .satisfied, to: .unsatisfied))
        #expect(!SystemEventMonitor.becameSatisfied(from: .unsatisfied, to: .requiresConnection))
    }

    @Test func theFirstUpdateOnlyReportsTheCurrentState() {
        #expect(!SystemEventMonitor.becameSatisfied(from: nil, to: .satisfied))
        #expect(!SystemEventMonitor.becameSatisfied(from: nil, to: .unsatisfied))
    }

    @Test @MainActor func startingDoesNotTriggerAPoll() async throws {
        let calls = Counter()
        let monitor = SystemEventMonitor(notificationCenter: NotificationCenter()) { calls.increment() }

        // The path monitor delivers the current path right after starting; that must not count.
        try await Task.sleep(for: .milliseconds(300))
        #expect(calls.value == 0)
        withExtendedLifetime(monitor) {}
    }

    @Test @MainActor func wakingUpCallsOnChangeUntilReleased() async {
        let center = NotificationCenter()
        let calls = Counter()
        do {
            let monitor = SystemEventMonitor(notificationCenter: center) { calls.increment() }
            center.post(name: NSWorkspace.didWakeNotification, object: nil)
            #expect(await waitUntil { calls.value == 1 })
            withExtendedLifetime(monitor) {}
        }

        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await stays(for: .milliseconds(100)) { calls.value == 1 })
    }

    @Test @MainActor func wakeNotificationsComeFromTheWorkspace() async {
        // Every other test gives its monitor a private center, so this post reaches only this monitor.
        let calls = Counter()
        let monitor = SystemEventMonitor { calls.increment() }

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await waitUntil { calls.value == 1 })
        withExtendedLifetime(monitor) {}
    }

    @Test @MainActor func aNetworkThatComesBackCallsOnChange() async {
        let calls = Counter()
        let monitor = SystemEventMonitor(notificationCenter: NotificationCenter()) { calls.increment() }

        monitor.pathDidChange(to: .unsatisfied)
        monitor.pathDidChange(to: .satisfied)
        #expect(await waitUntil { calls.value == 1 })
        monitor.pathDidChange(to: .satisfied)
        #expect(await stays(for: .milliseconds(100)) { calls.value == 1 })
    }
}

@MainActor
struct EditingWindowTests {
    private func keyDown(_ key: String, _ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: 0
        ))
    }

    @Test func standardEditingShortcutsSendTheirActions() throws {
        let shortcuts: [(key: String, modifiers: NSEvent.ModifierFlags, action: String)] = [
            ("x", .command, "cut:"),
            ("c", .command, "copy:"),
            ("v", .command, "paste:"),
            ("a", .command, "selectAll:"),
            ("z", .command, "undo:"),
            ("Z", [.command, .shift], "redo:"),
            ("w", .command, "performClose:"),
            // Caps Lock doesn't change a shortcut.
            ("C", [.command, .capsLock], "copy:"),
        ]
        for shortcut in shortcuts {
            let action = EditingWindow.action(for: try keyDown(shortcut.key, shortcut.modifiers))
            #expect(action.map(NSStringFromSelector) == shortcut.action, "\(shortcut.key)")
        }
    }

    @Test func otherKeysAreLeftToTheWindow() throws {
        let others: [(key: String, modifiers: NSEvent.ModifierFlags)] = [
            ("c", []),
            ("c", [.command, .shift]),
            ("c", [.command, .option]),
            ("z", [.command, .control]),
            ("q", .command),
            (",", .command),
        ]
        for other in others {
            #expect(EditingWindow.action(for: try keyDown(other.key, other.modifiers)) == nil, "\(other.key)")
        }
    }
}

struct TimeLimitTests {
    @Test func returnsAsSoonAsTheOperationFinishes() async {
        let finished = OSAllocatedUnfairLock(initialState: false)
        let start = ContinuousClock.now

        await withTimeLimit(.seconds(10)) {
            try? await Task.sleep(for: .milliseconds(20))
            finished.withLock { $0 = true }
        }

        #expect(finished.withLock { $0 })
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func givesUpAfterTheLimit() async {
        let start = ContinuousClock.now

        await withTimeLimit(.milliseconds(100)) {
            try? await Task.sleep(for: .seconds(3))
        }

        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .milliseconds(100))
        #expect(elapsed < .seconds(2))
    }
}

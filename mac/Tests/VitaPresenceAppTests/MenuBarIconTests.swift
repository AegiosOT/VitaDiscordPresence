import DiscordIPC
import PresenceKit
import Testing
@testable import VitaPresenceApp

struct MenuBarIconTests {
    static let activity = DiscordActivity(details: "Persona 4 Golden")

    @Test func symbols() {
        #expect(MenuBarIcon.presence.systemImage == nil)
        #expect(MenuBarIcon.attention.systemImage == "exclamationmark.triangle")
        #expect(MenuBarIcon.standby.systemImage == nil)
    }

    @Test func publishedPresenceFillsTheController() {
        let snapshot = PresenceSnapshot(isRunning: true, vita: .connected, publishedActivity: Self.activity)

        #expect(MenuBarIcon(snapshot: snapshot, hasSettingsIssues: false) == .presence)
    }

    @Test(arguments: [
        PresenceSnapshot.idle,
        PresenceSnapshot(isRunning: true, vita: .resolving, discord: .connecting),
        PresenceSnapshot(isRunning: true, vita: .connecting, discord: .connecting),
        PresenceSnapshot(isRunning: true, vita: .failing(.timedOut, failures: 4)),
        PresenceSnapshot(isRunning: true, vita: .connected, discord: .unavailable(.discordNotRunning)),
    ])
    func nothingToShowAndNothingToDo(snapshot: PresenceSnapshot) {
        #expect(MenuBarIcon(snapshot: snapshot, hasSettingsIssues: false) == .standby)
    }

    @Test(arguments: [
        PresenceSnapshot(isRunning: true, vita: .misconfigured(PresenceSettings.Issue.invalidAddress.message)),
        PresenceSnapshot(isRunning: true, vita: .failing(.localNetworkDenied, failures: 1)),
        PresenceSnapshot(isRunning: true, vita: .failing(.severalVitas(["192.0.2.20", "192.0.2.21"]), failures: 1)),
        PresenceSnapshot(isRunning: true, vita: .connected, discord: .unavailable(.invalidClientID)),
        // Asking for action wins over a presence that is still showing.
        PresenceSnapshot(isRunning: true, vita: .failing(.localNetworkDenied, failures: 1), publishedActivity: activity),
    ])
    func actionNeededShowsAWarning(snapshot: PresenceSnapshot) {
        #expect(MenuBarIcon(snapshot: snapshot, hasSettingsIssues: false) == .attention)
    }

    @Test func unusableSettingsShowAWarningEvenWhenStopped() {
        #expect(MenuBarIcon(snapshot: .idle, hasSettingsIssues: true) == .attention)
    }
}

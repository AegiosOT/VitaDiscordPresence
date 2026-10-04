import DiscordIPC
import Foundation
import PresenceKit
import Testing
@testable import VitaPresenceApp
import VitaKit

struct StatusTextTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let game = VitaTitle(index: 3, titleID: "PCSE00120", name: "Persona 4 Golden")
    let user = DiscordUser(id: "1", username: "alex", globalName: "Alex")

    static let durations: [Int] = [0, 42, 59, 60, 61, 12 * 60 + 5, 59 * 60 + 59, 3600, 3720, 3600 + 59 * 60, 25 * 3600 + 300]
    static let formatted: [String] = ["0s", "42s", "59s", "1m", "1m", "12m", "59m", "1h 00m", "1h 02m", "1h 59m", "25h 05m"]

    @Test(arguments: zip(durations, formatted))
    func elapsedTime(seconds: Int, expected: String) {
        #expect(StatusText.elapsed(from: start, to: start.addingTimeInterval(TimeInterval(seconds))) == expected)
    }

    @Test func elapsedTimeIsNeverNegative() {
        #expect(StatusText.elapsed(from: start, to: start.addingTimeInterval(-30)) == "0s")
    }

    @Test func stoppedIsASingleLine() {
        #expect(StatusText.lines(for: .idle, now: start) == ["Not connected"])
    }

    @Test func unusableSettingsShowOnlyTheIssue() {
        let snapshot = PresenceSnapshot(isRunning: true, vita: .misconfigured("Enter your Discord application ID"))

        #expect(StatusText.lines(for: snapshot, now: start) == ["Enter your Discord application ID"])
    }

    @Test func runningShowsTheGameThenVitaThenDiscord() {
        let snapshot = PresenceSnapshot(
            isRunning: true,
            vita: .connected,
            discord: .connected(user),
            title: game,
            sessionStart: start
        )

        #expect(StatusText.lines(for: snapshot, now: start.addingTimeInterval(3720)) == [
            "Persona 4 Golden — 1h 02m",
            "Vita: \(VitaStatus.connected.summary)",
            "Discord: \(DiscordStatus.connected(user).summary)",
        ])
    }

    @Test func noTitleMeansNoGameLine() {
        let snapshot = PresenceSnapshot(isRunning: true, vita: .failing(.timedOut, failures: 3), discord: .connecting)

        #expect(StatusText.lines(for: snapshot, now: start) == [
            "Vita: \(VitaStatus.failing(.timedOut, failures: 3).summary)",
            "Discord: \(DiscordStatus.connecting.summary)",
        ])
    }

    @Test func gameWithoutSessionStartHasNoElapsedTime() {
        let snapshot = PresenceSnapshot(isRunning: true, title: game)

        #expect(StatusText.game(for: snapshot, now: start) == "Persona 4 Golden")
    }

    @Test func liveAreaReadsNaturally() {
        let snapshot = PresenceSnapshot(isRunning: true, title: .liveArea, sessionStart: start)

        #expect(StatusText.game(for: snapshot, now: start.addingTimeInterval(300)) == "In the LiveArea — 5m")
    }

    @Test func titleIDStandsInForAMissingName() {
        let adrenaline = PresenceSnapshot(isRunning: true, title: VitaTitle(index: 2, titleID: "XMB", name: ""))
        let unnamed = PresenceSnapshot(isRunning: true, title: VitaTitle(index: 2, titleID: "", name: ""))

        #expect(StatusText.game(for: adrenaline, now: start) == "XMB")
        #expect(StatusText.game(for: unnamed, now: start) == "Unknown app")
    }
}

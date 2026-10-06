import DiscordIPC
import Foundation
import PresenceKit
import Testing
import VitaKit
@testable import VitaPresenceCLI

private let utc: StatusFormatter = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return StatusFormatter(calendar: calendar)
}()

private let persona = VitaTitle(index: 1, titleID: "PCSE00120", name: "Persona 4 Golden")
private let alex = DiscordUser(id: "1", username: "alex", globalName: "Alex")
private let noon = Date(timeIntervalSince1970: 1_700_000_000)  // 22:13:20 UTC

private func connected(_ title: VitaTitle? = persona, published: Bool = true) -> PresenceSnapshot {
    PresenceSnapshot(
        isRunning: true, vita: .connected, discord: .connected(alex), title: title, sessionStart: noon,
        host: "192.168.1.20", lastSuccess: noon, publishedActivity: published ? DiscordActivity(details: "x") : nil
    )
}

@Suite struct StatusFormatterTests {
    @Test func timestamps() {
        #expect(utc.timestamp(Date(timeIntervalSince1970: 0)) == "[00:00:00]")
        #expect(utc.timestamp(Date(timeIntervalSince1970: 3661)) == "[01:01:01]")
        #expect(utc.timestamp(noon) == "[22:13:20]")
        #expect(utc.clock(Date(timeIntervalSince1970: 86_399)) == "23:59:59")
    }

    @Test func timestampsUseTheCalendarsTimeZone() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 2 * 3600)!
        #expect(StatusFormatter(calendar: calendar).timestamp(noon) == "[00:13:20]")
    }

    @Test func statusLine() {
        // The summaries come from PresenceKit; this checks how the CLI assembles them.
        let shown = connected()
        #expect(utc.status(of: shown) == "Vita: \(shown.vita.summary) at 192.168.1.20 - Persona 4 Golden (PCSE00120) | "
            + "Discord: \(shown.discord.summary) | Presence: shown")
        let liveArea = connected(.liveArea, published: false)
        #expect(utc.status(of: liveArea) == "Vita: \(liveArea.vita.summary) at 192.168.1.20 - LiveArea | "
            + "Discord: \(liveArea.discord.summary) | Presence: not shown")
        let starting = PresenceSnapshot(isRunning: true, vita: .resolving, discord: .connecting)
        #expect(utc.status(of: starting)
            == "Vita: \(VitaStatus.resolving.summary) | Discord: \(DiscordStatus.connecting.summary) | Presence: not shown")
        let failing = PresenceSnapshot(
            isRunning: true, vita: .failing(.refused, failures: 3), discord: .unavailable(.discordNotRunning)
        )
        #expect(utc.status(of: failing) == "Vita: \(failing.vita.summary) | Discord: \(failing.discord.summary) | "
            + "Presence: not shown")
    }

    @Test func theHostShowsOnlyWhileTheVitaAnswers() {
        let trying = PresenceSnapshot(isRunning: true, vita: .connecting, discord: .connecting, host: "192.168.1.20")
        #expect(utc.status(of: trying).hasPrefix("Vita: \(VitaStatus.connecting.summary) | "))
        let failing = PresenceSnapshot(isRunning: true, vita: .failing(.timedOut, failures: 1), host: "192.168.1.20")
        #expect(utc.status(of: failing).hasPrefix("Vita: \(failing.vita.summary) | "))
        var unknownHost = connected()
        unknownHost.host = nil
        #expect(utc.status(of: unknownHost).hasPrefix("Vita: \(VitaStatus.connected.summary) - Persona 4 Golden"))
    }

    @Test func aPresenceWithAnImageSaysSo() {
        var withArtwork = connected()
        withArtwork.publishedActivity = DiscordActivity(
            name: "Persona 4 Golden",
            details: "PlayStation Vita",
            assets: DiscordActivity.Assets(largeImage: "https://example.com/p4g.png", largeText: "Persona 4 Golden")
        )
        #expect(utc.status(of: withArtwork).hasSuffix(" | Presence: shown with image"))
        // An image of the user's own Discord application counts too.
        withArtwork.publishedActivity?.assets?.largeImage = "vita-logo"
        #expect(utc.status(of: withArtwork).hasSuffix(" | Presence: shown with image"))
        // A small image alone isn't the picture next to the game.
        withArtwork.publishedActivity?.assets = DiscordActivity.Assets(largeImage: nil, smallImage: "vita-logo")
        #expect(utc.status(of: withArtwork).hasSuffix(" | Presence: shown"))
    }

    @Test func titles() {
        #expect(StatusFormatter.describe(persona) == "Persona 4 Golden (PCSE00120)")
        #expect(StatusFormatter.describe(.liveArea) == "LiveArea")
        #expect(StatusFormatter.describe(VitaTitle(index: 2, titleID: "PCSB00245", name: "")) == "PCSB00245")
        #expect(StatusFormatter.describe(VitaTitle(index: 2, titleID: "PCSB00245", name: "PCSB00245")) == "PCSB00245")
        #expect(StatusFormatter.describe(VitaTitle(index: 2, titleID: "", name: "Homebrew")) == "Homebrew")
        #expect(StatusFormatter.describe(VitaTitle(index: 3, titleID: "XMB", name: "Adrenaline XMB Menu"))
            == "Adrenaline XMB Menu (XMB)")
        // The LiveArea ignores whatever strings it carries.
        #expect(StatusFormatter.describe(VitaTitle(index: 0, titleID: "STALE", name: "Stale")) == "LiveArea")
    }

    @Test func details() {
        #expect(utc.details(of: connected()) == "host 192.168.1.20, session since 22:13:20, last answer 22:13:20")
        var withArtwork = connected()
        withArtwork.artwork = URL(string: "https://example.com/p4g.png")
        #expect(utc.details(of: withArtwork) == "host 192.168.1.20, session since 22:13:20, last answer 22:13:20, "
            + "artwork https://example.com/p4g.png")
        #expect(utc.details(of: PresenceSnapshot(isRunning: true, vita: .connecting, discord: .connecting)) == "")
        let once = PresenceSnapshot(isRunning: true, vita: .failing(.timedOut, failures: 1), host: "10.0.0.2")
        #expect(utc.details(of: once) == "host 10.0.0.2, 1 failed poll")
        let often = PresenceSnapshot(isRunning: true, vita: .failing(.timedOut, failures: 4))
        #expect(utc.details(of: often) == "4 failed polls")
    }

    @Test func startupLine() {
        var options = RunOptions()
        #expect(utc.startup(options) == "Starting vitapresence-cli 2.0.0: Vita automatic port 51966, "
            + "Discord application built-in (1556140114374037715), polling every 10 s. Press Ctrl-C to stop.")

        options.settings = PresenceSettings(address: " 192.168.1.20 ", clientID: " 123456789012345678\n")
        #expect(utc.startup(options) == "Starting vitapresence-cli 2.0.0: Vita 192.168.1.20 port 51966, "
            + "Discord application 123456789012345678, polling every 10 s. Press Ctrl-C to stop.")

        options.settings = PresenceSettings(
            address: "A4:5E:60:1:2:3",
            clientID: "  ",
            pollInterval: 4.5,
            showGameArtwork: false
        )
        options.port = 40000
        options.discordSocket = "/tmp/vp/discord-ipc-0"
        #expect(utc.startup(options) == "Starting vitapresence-cli 2.0.0: Vita a4:5e:60:01:02:03 port 40000, "
            + "Discord application built-in (1556140114374037715), polling every 4.5 s, no game artwork, "
            + "Discord socket /tmp/vp/discord-ipc-0. Press Ctrl-C to stop.")

        options.settings = PresenceSettings(address: "auto")
        #expect(utc.startup(options).hasPrefix("Starting vitapresence-cli 2.0.0: Vita automatic port 40000, "))
    }

    @Test func secondsFormatting() {
        #expect(Usage.seconds(10) == "10")
        #expect(Usage.seconds(3) == "3")
        #expect(Usage.seconds(300) == "300")
        #expect(Usage.seconds(4.5) == "4.5")
        #expect(Usage.seconds(0.25) == "0.25")
        #expect(Usage.seconds(100.05) == "100.05")
        // Never traps, whatever the value.
        #expect(Usage.seconds(.infinity) == "inf")
        #expect(Usage.seconds(.nan) == "nan")
        #expect(Usage.seconds(1e20) == "1e+20")
    }
}

@Suite struct StatusPrinterTests {
    @Test func printsOnlyChanges() {
        var printer = StatusPrinter(verbose: false, formatter: utc)
        let first = PresenceSnapshot(isRunning: true, vita: .connecting, discord: .connecting)
        #expect(printer.lines(for: first, at: noon) == ["[22:13:20] \(utc.status(of: first))"])
        #expect(printer.lines(for: first, at: noon).isEmpty)

        var later = connected()
        #expect(printer.lines(for: later, at: noon.addingTimeInterval(1)) == ["[22:13:21] \(utc.status(of: later))"])
        // A successful poll that changes nothing visible prints nothing.
        later.lastSuccess = noon.addingTimeInterval(10)
        #expect(printer.lines(for: later, at: noon.addingTimeInterval(10)).isEmpty)
        // The Vita moving to another address is news.
        later.host = "192.168.1.21"
        #expect(printer.lines(for: later, at: noon.addingTimeInterval(20)) == ["[22:13:40] \(utc.status(of: later))"])
        // Failures with the same message print once, however the count grows.
        let failing1 = PresenceSnapshot(isRunning: true, vita: .failing(.timedOut, failures: 1), discord: .connected(alex))
        let failing2 = PresenceSnapshot(isRunning: true, vita: .failing(.timedOut, failures: 2), discord: .connected(alex))
        #expect(printer.lines(for: failing1, at: noon).count == 1)
        #expect(printer.lines(for: failing2, at: noon).isEmpty)
        // Going back to an earlier status prints it again.
        #expect(printer.lines(for: first, at: noon).count == 1)
    }

    @Test func ignoresSnapshotsWhileNotRunning() {
        var printer = StatusPrinter(verbose: true, formatter: utc)
        #expect(printer.lines(for: .idle, at: noon).isEmpty)
        let running = PresenceSnapshot(isRunning: true, vita: .connecting, discord: .connecting)
        #expect(printer.lines(for: running, at: noon).count == 1)
        #expect(printer.lines(for: .idle, at: noon).isEmpty)
    }

    @Test func verbosePrintsEverySnapshotWithDetails() {
        var printer = StatusPrinter(verbose: true, formatter: utc)
        let snapshot = connected()
        let expected = "[22:13:20] \(utc.status(of: snapshot)) | host 192.168.1.20, session since 22:13:20, "
            + "last answer 22:13:20"
        #expect(printer.lines(for: snapshot, at: noon) == [expected])
        #expect(printer.lines(for: snapshot, at: noon) == [expected])
        let bare = PresenceSnapshot(isRunning: true, vita: .connecting, discord: .connecting)
        #expect(printer.lines(for: bare, at: noon) == ["[22:13:20] \(utc.status(of: bare))"])
    }

    @Test func localNetworkHintOncePerDenial() {
        for verbose in [false, true] {
            var printer = StatusPrinter(verbose: verbose, formatter: utc)
            let denied1 = PresenceSnapshot(
                isRunning: true, vita: .failing(.localNetworkDenied, failures: 1), discord: .connected(alex), title: persona
            )
            let lines = printer.lines(for: denied1, at: noon)
            #expect(lines.count == 2)
            let message = VitaConnectionError.localNetworkDenied.userMessage
            #expect(lines.first == "[22:13:20] Vita: \(message) - Persona 4 Golden (PCSE00120) | "
                + "Discord: \(DiscordStatus.connected(alex).summary) | Presence: not shown"
                + (verbose ? " | 1 failed poll" : ""))
            #expect(lines.last == Usage.localNetworkHint)

            // Still denied, but the title was dropped: the status line changes, the hint isn't repeated.
            let denied2 = PresenceSnapshot(
                isRunning: true, vita: .failing(.localNetworkDenied, failures: 2), discord: .connected(alex)
            )
            #expect(printer.lines(for: denied2, at: noon).count == 1)
            #expect(printer.lines(for: denied2, at: noon).count == (verbose ? 1 : 0))

            // After recovering, a new denial shows the hint again.
            #expect(printer.lines(for: connected(), at: noon).count == 1)
            #expect(printer.lines(for: denied2, at: noon).last == Usage.localNetworkHint)
        }
    }

    @Test func otherFailuresHaveNoHint() {
        var printer = StatusPrinter(verbose: false, formatter: utc)
        for error in [VitaConnectionError.timedOut, .refused, .unreachable("EHOSTUNREACH"), .other("x")] {
            let snapshot = PresenceSnapshot(isRunning: true, vita: .failing(error, failures: 1))
            #expect(printer.lines(for: snapshot, at: noon).count == 1)
        }
    }
}

@Suite struct ScanTableTests {
    @Test func alignsColumns() throws {
        let mac = try #require(MACAddress("a4:5e:60:01:02:03"))
        let table = ScanTable.render([
            DiscoveredVita(ipAddress: "192.168.1.31", macAddress: mac, title: persona),
            DiscoveredVita(ipAddress: "192.168.1.140", macAddress: nil, title: .liveArea),
            DiscoveredVita(ipAddress: "10.0.0.2", macAddress: nil, title: VitaTitle(index: 1, titleID: "XMB", name: "")),
        ])
        #expect(table == """
            IP ADDRESS     MAC ADDRESS        TITLE
            192.168.1.31   a4:5e:60:01:02:03  Persona 4 Golden (PCSE00120)
            192.168.1.140  -                  LiveArea
            10.0.0.2       -                  XMB
            """)
    }

    @Test func headerSetsTheMinimumWidth() {
        let table = ScanTable.render([DiscoveredVita(ipAddress: "1.2.3.4", macAddress: nil, title: .liveArea)])
        #expect(table == """
            IP ADDRESS  MAC ADDRESS  TITLE
            1.2.3.4     -            LiveArea
            """)
    }

    @Test func emptyResultIsJustTheHeader() {
        #expect(ScanTable.render([]) == "IP ADDRESS  MAC ADDRESS  TITLE")
    }
}

@Suite struct UsageTests {
    @Test func helpMentionsEveryOption() {
        let help = Usage.help
        for option in [
            "--address <ip|mac|auto>", "--client-id <id>", "--state <text>", "--interval <seconds>",
            "--large-image <key|url>", "--no-artwork", "--no-elapsed", "--hide-livearea", "--verbose", "--scan",
            "-h, --help", "--version", "--port <n>", "--discord-socket <path>",
        ] {
            #expect(help.contains(option), "\(option)")
        }
        #expect(help.contains("3 to 300 (default 10)"))
        #expect(help.contains("(default 51966)"))
        #expect(help.contains("Usage: vitapresence-cli [options]\n"))
        #expect(help.contains("vitapresence-cli <ip|mac> [<client-id>] [options]"))
        #expect(help.hasPrefix("vitapresence-cli 2.0.0: "))
        #expect(help.contains(Usage.synopsis))
    }

    @Test func textsFitEightyColumns() {
        for text in [Usage.help, Usage.synopsis, Usage.hint, Usage.localNetworkHint] {
            for line in text.split(separator: "\n") {
                #expect(line.count <= 80, "\(line)")
            }
        }
    }
}

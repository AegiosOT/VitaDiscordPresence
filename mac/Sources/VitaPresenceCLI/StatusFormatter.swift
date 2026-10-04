import Foundation
import PresenceKit
import VitaKit

/// Formats what `run` prints: time stamps, the startup line, and one status line per snapshot, such as
/// `[12:01:03] Vita: Connected - Persona 4 Golden (PCSE00120) | Discord: Connected as Alex | Presence: shown`.
struct StatusFormatter {
    /// Supplies the time zone of the time stamps.
    var calendar = Calendar.current

    /// `[12:01:03]`, 24-hour clock.
    func timestamp(_ date: Date) -> String {
        "[\(clock(date))]"
    }

    /// `12:01:03`, 24-hour clock.
    func clock(_ date: Date) -> String {
        let time = calendar.dateComponents([.hour, .minute, .second], from: date)
        return [time.hour, time.minute, time.second]
            .map { component in
                let value = component ?? 0
                return value < 10 ? "0\(value)" : "\(value)"
            }
            .joined(separator: ":")
    }

    /// Printed once before the first status line.
    func startup(_ options: RunOptions) -> String {
        let settings = options.settings
        let address = settings.vitaAddress?.description ?? settings.address
        var line = "Starting \(CommandLineTool.name) \(CommandLineTool.version): Vita \(address) port \(options.port), "
            + "Discord application \(settings.trimmedClientID), polling every \(Usage.seconds(settings.pollInterval)) s"
        if let socket = options.discordSocket {
            line += ", Discord socket \(socket)"
        }
        return line + ". Press Ctrl-C to stop."
    }

    /// The status line without its time stamp.
    func status(of snapshot: PresenceSnapshot) -> String {
        var vita = snapshot.vita.summary
        if let title = snapshot.title {
            vita += " - " + Self.describe(title)
        }
        let presence = snapshot.publishedActivity == nil ? "not shown" : "shown"
        return "Vita: \(vita) | Discord: \(snapshot.discord.summary) | Presence: \(presence)"
    }

    /// Extra facts for `--verbose`, or `""` when there are none.
    func details(of snapshot: PresenceSnapshot) -> String {
        var facts: [String] = []
        if let host = snapshot.host {
            facts.append("host \(host)")
        }
        if case .failing(_, let failures) = snapshot.vita {
            facts.append(failures == 1 ? "1 failed poll" : "\(failures) failed polls")
        }
        if let sessionStart = snapshot.sessionStart {
            facts.append("session since \(clock(sessionStart))")
        }
        if let lastSuccess = snapshot.lastSuccess {
            facts.append("last answer \(clock(lastSuccess))")
        }
        return facts.joined(separator: ", ")
    }

    /// `Persona 4 Golden (PCSE00120)`, or only the display name for the LiveArea and when there's no other
    /// title ID to show.
    static func describe(_ title: VitaTitle) -> String {
        let name = title.displayName
        guard !title.isLiveArea, !title.titleID.isEmpty, title.titleID != name else { return name }
        return "\(name) (\(title.titleID))"
    }
}

/// Decides what `run` prints for each snapshot: the status line when it changed, or every time with
/// `verbose` (followed by the details), and the Local Network hint when that failure begins. Snapshots of a
/// controller that isn't running (before `start`, after `stop`) print nothing, because the CLI announces
/// starting and stopping itself.
struct StatusPrinter {
    let verbose: Bool
    let formatter: StatusFormatter
    private var lastStatus: String?
    private var wasLocalNetworkDenied = false

    init(verbose: Bool, formatter: StatusFormatter = StatusFormatter()) {
        self.verbose = verbose
        self.formatter = formatter
    }

    /// The lines to print for `snapshot`, received at `date`; often none.
    mutating func lines(for snapshot: PresenceSnapshot, at date: Date) -> [String] {
        guard snapshot.isRunning else { return [] }
        let status = formatter.status(of: snapshot)
        let isLocalNetworkDenied = Self.isLocalNetworkDenied(snapshot.vita)
        defer {
            lastStatus = status
            wasLocalNetworkDenied = isLocalNetworkDenied
        }

        var lines: [String] = []
        if status != lastStatus || verbose {
            let details = verbose ? formatter.details(of: snapshot) : ""
            lines.append("\(formatter.timestamp(date)) \(status)" + (details.isEmpty ? "" : " | \(details)"))
        }
        if isLocalNetworkDenied && !wasLocalNetworkDenied {
            lines.append(Usage.localNetworkHint)
        }
        return lines
    }

    private static func isLocalNetworkDenied(_ status: VitaStatus) -> Bool {
        if case .failing(.localNetworkDenied, _) = status { return true }
        return false
    }
}

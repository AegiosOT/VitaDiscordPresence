import Foundation
import PresenceKit

/// The status lines shown in the menu and at the bottom of the Settings window.
enum StatusText {
    /// Lines describing `snapshot`: the game with its elapsed time (when known), then the Vita and Discord
    /// status. A stopped controller is a single "Not connected" line, and unusable settings show their issue.
    static func lines(for snapshot: PresenceSnapshot, now: Date) -> [String] {
        guard snapshot.isRunning else { return ["Not connected"] }
        if case .misconfigured(let message) = snapshot.vita { return [message] }
        var lines: [String] = []
        if let game = game(for: snapshot, now: now) {
            lines.append(game)
        }
        lines.append("Vita: \(snapshot.vita.summary)")
        lines.append("Discord: \(snapshot.discord.summary)")
        return lines
    }

    /// "Persona 4 Golden — 1h 02m", or `nil` when no title is known.
    static func game(for snapshot: PresenceSnapshot, now: Date) -> String? {
        guard let title = snapshot.title else { return nil }
        let name = title.isLiveArea ? "In the LiveArea" : title.displayName.isEmpty ? "Unknown app" : title.displayName
        guard let start = snapshot.sessionStart else { return name }
        return "\(name) — \(elapsed(from: start, to: now))"
    }

    /// Compact elapsed time: "42s", "12m", "1h 02m".
    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let remainder = minutes % 60
        return "\(minutes / 60)h \(remainder < 10 ? "0" : "")\(remainder)m"
    }
}

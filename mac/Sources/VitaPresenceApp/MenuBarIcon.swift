import PresenceKit
import SwiftUI

/// The menu bar symbol, which sums up the state at a glance.
enum MenuBarIcon: Equatable {
    /// A presence is showing on Discord.
    case presence
    /// The user has to do something: allow Local Network access, fix the client ID or the settings.
    case attention
    /// Anything else: stopped, connecting, or nothing to show.
    case standby

    init(snapshot: PresenceSnapshot, hasSettingsIssues: Bool) {
        if hasSettingsIssues || Self.needsAttention(snapshot) {
            self = .attention
        } else if snapshot.publishedActivity != nil {
            self = .presence
        } else {
            self = .standby
        }
    }

    var systemImage: String {
        switch self {
        case .presence: "gamecontroller.fill"
        case .attention: "exclamationmark.triangle"
        case .standby: "gamecontroller"
        }
    }

    private static func needsAttention(_ snapshot: PresenceSnapshot) -> Bool {
        switch snapshot.vita {
        case .misconfigured, .failing(.localNetworkDenied, _), .failing(.severalVitas, _): true
        default: snapshot.discord == .unavailable(.invalidClientID)
        }
    }
}

/// The `MenuBarExtra` label: the current `MenuBarIcon`.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Image(systemName: model.menuBarIcon.systemImage)
            .accessibilityLabel("VitaPresence")
    }
}

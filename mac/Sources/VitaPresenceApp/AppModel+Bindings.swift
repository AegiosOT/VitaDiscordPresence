import PresenceKit
import SwiftUI

/// Bindings over the model for the views, which keep no state of their own. They all read the draft.
extension AppModel {
    /// A binding to a text setting. Typing changes the draft, which is committed once typing pauses.
    func textBinding(for keyPath: WritableKeyPath<PresenceSettings, String> & Sendable) -> Binding<String> {
        Binding(
            get: { self.draft[keyPath: keyPath] },
            set: { value in self.editDraft { $0[keyPath: keyPath] = value } }
        )
    }

    /// A binding to a setting such as a toggle. Every change is saved and applied right away.
    func binding<Value>(for keyPath: WritableKeyPath<PresenceSettings, Value> & Sendable) -> Binding<Value> {
        Binding(
            get: { self.draft[keyPath: keyPath] },
            set: { value in self.updateSettings { $0[keyPath: keyPath] = value } }
        )
    }

    /// The poll interval in seconds, clamped to `PresenceSettings.pollIntervalRange`, applied right away.
    var pollIntervalBinding: Binding<Double> {
        Binding(
            get: { self.draft.pollInterval },
            set: { value in
                guard value.isFinite else { return }
                let range = PresenceSettings.pollIntervalRange
                self.updateSettings { $0.pollInterval = min(max(value, range.lowerBound), range.upperBound) }
            }
        )
    }

    var connectOnLaunchBinding: Binding<Bool> {
        Binding(get: { self.connectOnLaunch }, set: { self.setConnectOnLaunch($0) })
    }

    /// "Use my own Discord application": shows the application ID field; turning it off clears the ID.
    var ownDiscordApplicationBinding: Binding<Bool> {
        Binding(get: { self.usesOwnDiscordApplication }, set: { self.setUsesOwnDiscordApplication($0) })
    }

    /// A profile's name. Typing is saved as it happens; a blank name is shown as "PS Vita".
    func profileNameBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { self.profiles.first { $0.id == id }?.name ?? "" },
            set: { self.renameProfile(id, to: $0) }
        )
    }

    /// On only while launch at login is fully enabled; turning it on may ask for approval instead.
    var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { self.launchAtLogin == .enabled }, set: { self.setLaunchAtLogin($0) })
    }
}

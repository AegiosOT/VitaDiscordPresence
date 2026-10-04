import Foundation
import PresenceKit

/// Saves the app's settings in `UserDefaults`: the `PresenceSettings` as a JSON blob under `settings.v1`,
/// and whether to connect at launch under `connectOnLaunch`.
struct SettingsStore {
    static let settingsKey = "settings.v1"
    static let connectOnLaunchKey = "connectOnLaunch"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The saved settings, or the defaults when nothing readable is saved.
    var settings: PresenceSettings {
        get {
            guard let data = defaults.data(forKey: Self.settingsKey),
                  let settings = try? JSONDecoder().decode(PresenceSettings.self, from: data)
            else { return PresenceSettings() }
            return settings
        }
        nonmutating set {
            // Encoding only fails for a non-finite poll interval; keep the last good value then.
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Self.settingsKey)
        }
    }

    /// Whether to connect when the app launches; `true` until the user turns it off.
    var connectOnLaunch: Bool {
        get { defaults.object(forKey: Self.connectOnLaunchKey) == nil || defaults.bool(forKey: Self.connectOnLaunchKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.connectOnLaunchKey) }
    }
}

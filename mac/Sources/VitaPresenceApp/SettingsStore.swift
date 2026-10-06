import Foundation
import PresenceKit
import VitaKit

/// Saves the app's settings in `UserDefaults`: the `PresenceSettings` as a JSON blob under `settings.v1`,
/// whether to connect at launch under `connectOnLaunch`, where the Vita last answered under `lastVitaHost`,
/// and the saved consoles under `vitaProfiles.v1`.
struct SettingsStore {
    static let settingsKey = "settings.v1"
    static let connectOnLaunchKey = "connectOnLaunch"
    static let lastVitaHostKey = "lastVitaHost"
    static let profilesKey = "vitaProfiles.v1"
    static let selectedProfileIDKey = "selectedVitaProfileID"

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

    /// The IPv4 address the Vita last answered on, so the next launch can poll it before scanning the network.
    /// `nil` when nothing is saved, or when what is saved isn't an IPv4 address.
    var lastVitaHost: String? {
        get {
            guard let text = defaults.string(forKey: Self.lastVitaHostKey),
                  case .ipv4(let host) = VitaAddress(text)
            else { return nil }
            return host
        }
        nonmutating set { defaults.set(newValue, forKey: Self.lastVitaHostKey) }
    }

    /// Consoles this Mac has connected to, oldest first. Unreadable data and addresses that aren't IPv4 are
    /// left out.
    var profiles: [VitaProfile] {
        get {
            guard let data = defaults.data(forKey: Self.profilesKey),
                  let profiles = try? JSONDecoder().decode([VitaProfile].self, from: data)
            else { return [] }
            return profiles.compactMap(Self.usable)
        }
        nonmutating set {
            guard let data = try? JSONEncoder().encode(newValue.compactMap(Self.usable)) else { return }
            defaults.set(data, forKey: Self.profilesKey)
        }
    }

    /// Which saved console to connect to. `nil` when none is selected, or when the saved value isn't a UUID.
    var selectedProfileID: UUID? {
        get {
            guard let text = defaults.string(forKey: Self.selectedProfileIDKey) else { return nil }
            return UUID(uuidString: text)
        }
        nonmutating set { defaults.set(newValue?.uuidString, forKey: Self.selectedProfileIDKey) }
    }

    /// The selected profile, or the last host from a version that didn't save profiles yet.
    var rememberedVita: RememberedVita {
        if let profile = profiles.first(where: { $0.id == selectedProfileID }) {
            return RememberedVita(host: profile.lastAddress, macAddress: profile.mac)
        }
        return RememberedVita(host: lastVitaHost, macAddress: nil)
    }

    /// Turns a `lastVitaHost` saved before profiles existed into one profile, once. Does nothing once
    /// `vitaProfiles.v1` is present, including when every profile has been removed.
    func migrateProfilesIfNeeded() {
        guard defaults.object(forKey: Self.profilesKey) == nil, let host = lastVitaHost else { return }
        let profile = VitaProfile(
            id: UUID(),
            name: VitaProfile.defaultName,
            lastAddress: host,
            macAddress: nil,
            lastSeen: Date()
        )
        profiles = [profile]
        selectedProfileID = profile.id
    }

    /// `profile` when its address is an IPv4 address, with that address normalized. A MAC address that doesn't
    /// parse is dropped rather than rejecting the whole profile.
    private static func usable(_ profile: VitaProfile) -> VitaProfile? {
        guard case .ipv4(let host) = VitaAddress(profile.lastAddress) else { return nil }
        var profile = profile
        profile.lastAddress = host
        if let mac = profile.macAddress {
            profile.macAddress = MACAddress(mac)?.description
        }
        return profile
    }
}

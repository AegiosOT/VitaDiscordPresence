import Foundation
import PresenceKit
import Testing
@testable import VitaPresenceApp

struct SettingsStoreTests {
    @Test func emptyDefaultsGiveDefaultSettingsAndConnectOnLaunch() throws {
        let temporary = try TemporaryDefaults()
        let store = SettingsStore(defaults: temporary.defaults)

        #expect(store.settings == PresenceSettings())
        #expect(store.connectOnLaunch)
    }

    @Test func settingsAreSavedAsJSONUnderTheVersionedKey() throws {
        let temporary = try TemporaryDefaults()
        let settings = PresenceSettings(
            address: "192.168.1.20",
            clientID: "123456789012345678",
            stateText: "Grinding",
            largeImageKey: "vita",
            pollInterval: 30,
            showElapsedTime: false,
            showLiveArea: false
        )

        SettingsStore(defaults: temporary.defaults).settings = settings

        let data = try #require(temporary.defaults.data(forKey: "settings.v1"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["address"] as? String == "192.168.1.20")
        // A new store over the same defaults is what the next launch sees.
        #expect(SettingsStore(defaults: temporary.defaults).settings == settings)
    }

    @Test func unreadableSettingsFallBackToDefaults() throws {
        let temporary = try TemporaryDefaults()
        temporary.defaults.set(Data("not json".utf8), forKey: "settings.v1")

        #expect(SettingsStore(defaults: temporary.defaults).settings == PresenceSettings())
    }

    @Test func connectOnLaunchIsSavedUnderItsOwnKey() throws {
        let temporary = try TemporaryDefaults()
        let store = SettingsStore(defaults: temporary.defaults)

        store.connectOnLaunch = false
        #expect(temporary.defaults.object(forKey: "connectOnLaunch") as? Bool == false)
        #expect(SettingsStore(defaults: temporary.defaults).connectOnLaunch == false)

        store.connectOnLaunch = true
        #expect(SettingsStore(defaults: temporary.defaults).connectOnLaunch)
    }

    @Test func nonFiniteSettingsDontReplaceTheSavedOnes() throws {
        let temporary = try TemporaryDefaults()
        let store = SettingsStore(defaults: temporary.defaults)
        store.settings = validSettings

        var broken = validSettings
        broken.pollInterval = .nan
        store.settings = broken

        #expect(store.settings == validSettings)
    }
}

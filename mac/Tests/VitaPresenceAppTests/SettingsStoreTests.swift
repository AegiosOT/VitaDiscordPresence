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
        #expect(store.lastVitaHost == nil)
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
            showLiveArea: false,
            showGameArtwork: false
        )

        SettingsStore(defaults: temporary.defaults).settings = settings

        let data = try #require(temporary.defaults.data(forKey: "settings.v1"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["address"] as? String == "192.168.1.20")
        #expect(json["showGameArtwork"] as? Bool == false)
        // A new store over the same defaults is what the next launch sees.
        #expect(SettingsStore(defaults: temporary.defaults).settings == settings)
    }

    @Test func settingsSavedBeforeArtworkExistedShowArtwork() throws {
        let temporary = try TemporaryDefaults()
        let older = #"{"address":"192.168.1.20","clientID":"123456789012345678","pollInterval":10}"#
        temporary.defaults.set(Data(older.utf8), forKey: "settings.v1")

        let settings = SettingsStore(defaults: temporary.defaults).settings

        #expect(settings == PresenceSettings(address: "192.168.1.20", clientID: "123456789012345678"))
        #expect(settings.showGameArtwork)
    }

    @Test func theLastVitaHostIsSavedUnderItsOwnKey() throws {
        let temporary = try TemporaryDefaults()
        let store = SettingsStore(defaults: temporary.defaults)

        store.lastVitaHost = "192.168.1.20"
        #expect(temporary.defaults.string(forKey: "lastVitaHost") == "192.168.1.20")
        #expect(SettingsStore(defaults: temporary.defaults).lastVitaHost == "192.168.1.20")

        store.lastVitaHost = nil
        #expect(temporary.defaults.object(forKey: "lastVitaHost") == nil)
        #expect(store.lastVitaHost == nil)
    }

    @Test func aSavedHostIsNormalized() throws {
        let temporary = try TemporaryDefaults()
        temporary.defaults.set(" 192.168.1.20\n", forKey: "lastVitaHost")

        #expect(SettingsStore(defaults: temporary.defaults).lastVitaHost == "192.168.1.20")
    }

    @Test(arguments: ["", "auto", "192.168.1", "192.168.001.020", "a4:5e:60:01:02:03", "vita.local"])
    func onlyAnIPv4AddressCountsAsTheLastVitaHost(saved: String) throws {
        let temporary = try TemporaryDefaults()
        temporary.defaults.set(saved, forKey: "lastVitaHost")

        #expect(SettingsStore(defaults: temporary.defaults).lastVitaHost == nil)
    }

    @Test func aLastVitaHostOfAnotherTypeIsIgnored() throws {
        let temporary = try TemporaryDefaults()
        temporary.defaults.set(["192.168.1.20"], forKey: "lastVitaHost")

        #expect(SettingsStore(defaults: temporary.defaults).lastVitaHost == nil)
    }

    @Test func aSavedHostBecomesOneProfile() throws {
        let temporary = try TemporaryDefaults()
        let store = SettingsStore(defaults: temporary.defaults)
        store.lastVitaHost = "192.168.1.20"

        store.migrateProfilesIfNeeded()

        let profiles = store.profiles
        #expect(profiles.count == 1)
        #expect(profiles[0].name == VitaProfile.defaultName)
        #expect(profiles[0].lastAddress == "192.168.1.20")
        #expect(profiles[0].macAddress == nil)
        #expect(store.selectedProfileID == profiles[0].id)
        #expect(store.rememberedVita == RememberedVita(host: "192.168.1.20", macAddress: nil))
        // A second launch must not add another copy.
        store.migrateProfilesIfNeeded()
        #expect(store.profiles.count == 1)
    }

    @Test func profilesRoundTripAndARemovedListIsNotRecreatedFromTheOldHost() throws {
        let temporary = try TemporaryDefaults()
        let store = SettingsStore(defaults: temporary.defaults)
        let profile = VitaProfile(
            id: UUID(),
            name: "Living room",
            lastAddress: "192.168.1.20",
            macAddress: "A4:5E:60:01:02:03",
            lastSeen: Date(timeIntervalSince1970: 1_700_000_000)
        )
        store.profiles = [profile]
        store.selectedProfileID = profile.id

        let loaded = SettingsStore(defaults: temporary.defaults)
        #expect(loaded.profiles == [
            VitaProfile(
                id: profile.id,
                name: "Living room",
                lastAddress: "192.168.1.20",
                macAddress: "a4:5e:60:01:02:03",
                lastSeen: profile.lastSeen
            ),
        ])
        #expect(loaded.selectedProfileID == profile.id)
        #expect(loaded.rememberedVita.host == "192.168.1.20")
        #expect(loaded.rememberedVita.macAddress?.description == "a4:5e:60:01:02:03")

        loaded.profiles = []
        loaded.selectedProfileID = nil
        loaded.lastVitaHost = "192.168.1.20"
        loaded.migrateProfilesIfNeeded()
        #expect(loaded.profiles.isEmpty)
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

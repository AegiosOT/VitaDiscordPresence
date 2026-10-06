import Foundation
import Testing
import VitaKit
@testable import PresenceKit

@Suite struct PresenceSettingsTests {
    private func decode(_ json: String) throws -> PresenceSettings {
        try JSONDecoder().decode(PresenceSettings.self, from: Data(json.utf8))
    }

    // MARK: Decoding

    @Test func decodesEveryKey() throws {
        let settings = try decode("""
            {"address":"192.168.1.20","clientID":"123456789012345678","stateText":"Playing on PS TV",
             "largeImageKey":"vita","pollInterval":15,"showElapsedTime":false,"showLiveArea":false,
             "showGameArtwork":false}
            """)
        #expect(settings == PresenceSettings(
            address: "192.168.1.20",
            clientID: "123456789012345678",
            stateText: "Playing on PS TV",
            largeImageKey: "vita",
            pollInterval: 15,
            showElapsedTime: false,
            showLiveArea: false,
            showGameArtwork: false
        ))
    }

    @Test func missingKeysFallBackToDefaults() throws {
        #expect(try decode("{}") == PresenceSettings())
        let settings = try decode(#"{"address":"a4:5e:60:01:02:03","showLiveArea":false}"#)
        #expect(settings == PresenceSettings(address: "a4:5e:60:01:02:03", showLiveArea: false))
    }

    @Test func mistypedKeysFallBackToDefaults() throws {
        let settings = try decode("""
            {"address":42,"clientID":"123456789012345678","stateText":null,"largeImageKey":["vita"],
             "pollInterval":"fast","showElapsedTime":"yes","showLiveArea":0,"showGameArtwork":"no"}
            """)
        #expect(settings == PresenceSettings(clientID: "123456789012345678"))
    }

    @Test func unknownKeysAreIgnored() throws {
        let settings = try decode(#"{"clientID":"123456789012345678","theme":"dark","version":3}"#)
        #expect(settings == PresenceSettings(clientID: "123456789012345678"))
    }

    @Test func notAnObjectThrows() {
        #expect(throws: DecodingError.self) { try decode("[1, 2, 3]") }
    }

    @Test func encodesWithThePropertyNamesAndRoundTrips() throws {
        let settings = PresenceSettings(
            address: "192.168.1.20",
            clientID: "123456789012345678",
            stateText: "Hi",
            largeImageKey: "https://example.com/vita.png",
            pollInterval: 7.5,
            showElapsedTime: false,
            showLiveArea: true
        )
        let data = try JSONEncoder().encode(settings)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == [
            "address", "clientID", "stateText", "largeImageKey", "pollInterval", "showElapsedTime", "showLiveArea",
            "showGameArtwork",
        ])
        #expect(try JSONDecoder().decode(PresenceSettings.self, from: data) == settings)
    }

    // MARK: Derived values

    @Test(arguments: [
        (10.0, Duration.seconds(10)),
        (3, .seconds(3)),
        (300, .seconds(300)),
        (7.5, .milliseconds(7500)),
        (1, .seconds(3)),
        (-5, .seconds(3)),
        (1000, .seconds(300)),
        (.nan, .seconds(10)),
        (.infinity, .seconds(10)),
        (-.infinity, .seconds(10)),
    ])
    func effectivePollIntervalIsClamped(pollInterval: Double, expected: Duration) {
        #expect(PresenceSettings(pollInterval: pollInterval).effectivePollInterval == expected)
    }

    @Test func trimmedClientIDRemovesSurroundingWhitespace() {
        #expect(PresenceSettings(clientID: " \t123456789012345678\n").trimmedClientID == "123456789012345678")
        #expect(PresenceSettings(clientID: "12345 678").trimmedClientID == "12345 678")
    }

    @Test func defaultsFindTheVitaAndUseTheBuiltInApplication() {
        let settings = PresenceSettings()
        #expect(settings.vitaAddress == .automatic)
        #expect(settings.effectiveClientID == PresenceSettings.defaultClientID)
        #expect(!settings.usesCustomClientID)
        #expect(settings.showGameArtwork)
        #expect(PresenceSettings(clientID: PresenceSettings.defaultClientID).issues.isEmpty)
    }

    @Test(arguments: ["", "   ", "auto", "Automatic"])
    func blankOrAutoAddressMeansAutomatic(address: String) {
        #expect(PresenceSettings(address: address).vitaAddress == .automatic)
    }

    @Test func customClientIDReplacesTheBuiltInOne() {
        let custom = PresenceSettings(clientID: " 123456789012345678 ")
        #expect(custom.usesCustomClientID)
        #expect(custom.effectiveClientID == "123456789012345678")
        let blank = PresenceSettings(clientID: " \n")
        #expect(!blank.usesCustomClientID)
        #expect(blank.effectiveClientID == PresenceSettings.defaultClientID)
    }

    // MARK: Issues

    @Test func usableSettingsHaveNoIssues() {
        #expect(PresenceSettings.valid.issues.isEmpty)
        #expect(PresenceSettings(address: " 192.168.1.20 ", clientID: " 1234567890123456 ").issues.isEmpty)
        #expect(PresenceSettings(address: "A4-5E-60-01-02-03", clientID: "1234567890123456789012345").issues.isEmpty)
    }

    @Test func defaultSettingsAreUsable() {
        #expect(PresenceSettings().issues.isEmpty)
        #expect(PresenceSettings(address: "  ", clientID: "\n").issues.isEmpty)
    }

    @Test(arguments: ["192.168.1", "192.168.1.256", "vita.local", "192.168.1.20:51966", "a4:5e:60:01:02"])
    func invalidAddressIsReported(address: String) {
        #expect(PresenceSettings(address: address, clientID: validClientID).issues == [.invalidAddress])
    }

    @Test(arguments: [
        "123456789012345",  // 15 digits
        "12345678901234567890123456",  // 26 digits
        "12345678901234567a",
        "1234567890 12345678",
        "-123456789012345678",
        "１２３４５６７８９０１２３４５６７８",  // full-width digits
        "١٢٣٤٥٦٧٨٩٠١٢٣٤٥٦٧٨",  // Arabic-Indic digits
    ])
    func invalidClientIDIsReported(clientID: String) {
        #expect(PresenceSettings(address: "192.168.1.20", clientID: clientID).issues == [.invalidClientID])
    }

    @Test func addressIssueComesBeforeClientIDIssue() {
        #expect(PresenceSettings(address: "nope", clientID: "12").issues == [.invalidAddress, .invalidClientID])
    }

    @Test func issueMessages() {
        #expect(PresenceSettings.Issue.invalidAddress.message == "That isn't a valid IP or MAC address")
        #expect(PresenceSettings.Issue.invalidClientID.message == "The application ID should be 16 to 25 digits")
    }
}

import DiscordIPC
import Foundation
import Testing
import TestSupport
@testable import VitaPresenceApp

/// The menu-bar app's Discord connection lives in `vitapresence-discord`. Disconnecting exits that process
/// and does not send a null activity, which would leave the application's name on screen.
struct DiscordHelperClientTests {
    private static let clientID = "123456789012345678"

    @Test func disconnectExitsTheHelperWithoutANullActivity() async throws {
        let server = try MockDiscordServer()
        defer { server.stop() }
        let client = DiscordHelperClient(executable: try helperExecutable(), socketPath: server.socketPath)

        let user = try await client.connect(clientID: Self.clientID)
        #expect(user == DiscordUser(id: "1", username: "tester", globalName: "Tester"))
        #expect(await client.isConnected)
        #expect(await client.isHelperRunning)
        #expect(await client.helperStandsAlone())

        try await client.setActivity(DiscordActivity(name: "Persona 4 Golden", details: "PlayStation Vita"))
        let command = try JSONSerialization.jsonObject(with: try #require(server.commands.last)) as? [String: Any]
        let arguments = try #require(command?["args"] as? [String: Any])
        let activity = try #require(arguments["activity"] as? [String: Any])
        #expect(activity["name"] as? String == "Persona 4 Golden")
        #expect(activity["details"] as? String == "PlayStation Vita")

        await client.disconnect()
        #expect(await !client.isConnected)
        #expect(await !client.isHelperRunning)
        #expect(server.openConnectionCount == 0)
        #expect(server.receivedFrames.map(\.opcode) == [.handshake, .frame, .close])
        for payload in server.commands {
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
            let args = object?["args"] as? [String: Any]
            #expect(!(args?["activity"] is NSNull), "an empty activity would show the application's name")
        }

        await client.disconnect()
        #expect(server.connectionCount == 1)
    }

    @Test func connectPublishesTheGameBeforeItReportsReady() async throws {
        let server = try MockDiscordServer()
        defer { server.stop() }
        let client = DiscordHelperClient(executable: try helperExecutable(), socketPath: server.socketPath)
        let game = DiscordActivity(name: "Persona 4 Golden", details: "PlayStation Vita")

        _ = try await client.connect(clientID: Self.clientID, activity: game)

        let command = try JSONSerialization.jsonObject(with: try #require(server.commands.last)) as? [String: Any]
        let arguments = try #require(command?["args"] as? [String: Any])
        let activity = try #require(arguments["activity"] as? [String: Any])
        #expect(activity["name"] as? String == "Persona 4 Golden")
        #expect(server.receivedFrames.map(\.opcode) == [.handshake, .frame])
        await client.disconnect()
    }

    @Test func aMissingHelperFailsToConnect() async throws {
        let client = DiscordHelperClient(executable: URL(fileURLWithPath: "/tmp/vitapresence-discord-missing"))
        await #expect(throws: DiscordIPCError.io("The Discord helper is missing")) {
            try await client.connect(clientID: Self.clientID)
        }
        #expect(await !client.isConnected)
    }
}

/// `vitapresence-discord` built next to this test bundle.
private func helperExecutable() throws -> URL {
    let executable = Bundle(for: HelperBundleAnchor.self).bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("vitapresence-discord")
    try #require(FileManager.default.isExecutableFile(atPath: executable.path), "\(executable.path) is missing")
    return executable
}

private final class HelperBundleAnchor: NSObject {}

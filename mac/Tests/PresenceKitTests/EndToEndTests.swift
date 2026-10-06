import DiscordIPC
import Foundation
import Testing
import TestSupport
import VitaKit
@testable import PresenceKit

/// The controller with the real `VitaClient`, `VitaResolver` and `DiscordIPCClient`, against the loopback
/// mock Vita plugin and mock Discord. Artwork comes from a `FakeArtwork`, so nothing leaves the machine.
@Suite(.serialized) struct EndToEnd {
    private let game = VitaTitle(index: 2, titleID: "PCSE00120", name: "Persona 4 Golden")
    private let nextGame = VitaTitle(index: 4, titleID: "PCSA00011", name: "Gravity Rush")
    private let clientID = "123456789012345678"

    @Test func presenceFollowsTheVitaAndStopDisconnects() async throws {
        let vita = try await MockVitaServer(behavior: .packet(game))
        defer { vita.stop() }
        let discord = try MockDiscordServer()
        defer { discord.stop() }

        var configuration = PresenceController.Configuration()
        configuration.pollIntervalOverride = .milliseconds(100)
        configuration.minimumRetryDelay = .milliseconds(100)
        configuration.maximumRetryDelay = .milliseconds(200)
        configuration.clearAfterFailures = 2
        configuration.activityBurst = 20
        configuration.activityWindow = .seconds(1)
        configuration.artworkGrace = .zero
        let socketPath = discord.socketPath
        // Only the first game has artwork, and it arrives a little after the text.
        let artwork = FakeArtwork([game.titleID: personaArt], delay: .milliseconds(300))
        let controller = PresenceController(
            fetcher: VitaClient(port: vita.port, connectTimeout: .milliseconds(500), readTimeout: .seconds(1)),
            resolver: VitaResolver(),
            discord: DiscordIPCClient(socketPaths: { [socketPath] }, timeout: .seconds(2)),
            artwork: artwork,
            configuration: configuration
        )

        do {
            try await exercise(controller, vita: vita, discord: discord, artwork: artwork)
        } catch {
            await controller.stop()
            throw error
        }
    }

    private func exercise(
        _ controller: PresenceController,
        vita: MockVitaServer,
        discord: MockDiscordServer,
        artwork: FakeArtwork
    ) async throws {
        func names() -> [String?] {
            setActivities(discord).map { $0?["name"] as? String }
        }

        // The game is the activity's name, with the platform under it; its artwork follows the text.
        await controller.start(with: PresenceSettings(address: "127.0.0.1", clientID: " \(clientID) "))
        #expect(await eventually(timeout: .seconds(5)) { names().contains(game.name) })
        let text = try #require(setActivities(discord).first { $0?["name"] as? String == game.name } ?? nil)
        #expect(text["type"] as? Int == 0)
        #expect(text["details"] as? String == "PlayStation Vita")
        #expect(text["assets"] == nil)
        #expect(await eventually(timeout: .seconds(5)) { largeImage(of: setActivities(discord).last ?? nil) != nil })
        let withArtwork = try #require(setActivities(discord).last ?? nil)
        #expect(withArtwork["name"] as? String == game.name)
        let assets = try #require(withArtwork["assets"] as? [String: Any])
        #expect(assets["large_image"] as? String == personaArt.absoluteString)
        #expect(assets["large_text"] as? String == "Persona 4 Golden (PCSE00120)")
        let handshake = try #require(discord.handshakes.first)
        let handshakeJSON = try #require(try JSONSerialization.jsonObject(with: handshake) as? [String: Any])
        #expect(handshakeJSON["client_id"] as? String == clientID)
        #expect(await eventually { await controller.snapshot.discord == .connected(MockDiscordServer.defaultUser) })
        let snapshot = await controller.snapshot
        #expect(snapshot.title == game)
        #expect(snapshot.host == "127.0.0.1")
        #expect(snapshot.artwork == personaArt)

        // A title change propagates; the next game has no artwork, so its update has no image.
        vita.setBehavior(.packet(nextGame))
        #expect(await eventually(timeout: .seconds(5)) { names().last == nextGame.name })
        #expect(await eventually { await artwork.answered.contains(nextGame.titleID) })
        #expect(largeImage(of: setActivities(discord).last ?? nil) == nil)
        #expect(await controller.snapshot.artwork == nil)

        // Connections that close without a packet clear the presence after `clearAfterFailures` polls.
        vita.setBehavior(.closeImmediately)
        #expect(await eventually(timeout: .seconds(5)) { setActivities(discord).last.map { $0 == nil } ?? false })
        #expect(await controller.snapshot.title == nil)
        if case .failing(_, let failures) = await controller.snapshot.vita {
            #expect(failures >= 2)
        } else {
            Issue.record("expected the Vita to be failing")
        }

        // The Vita answers again, and the artwork found earlier is shown at once.
        vita.setBehavior(.packet(game))
        #expect(await eventually(timeout: .seconds(5)) { names().last == game.name })
        #expect(largeImage(of: setActivities(discord).last ?? nil) == personaArt.absoluteString)
        #expect(await artwork.lookedUp == [game.titleID, nextGame.titleID])

        // The client answers PINGs while connected...
        let probe = Data(#"{"probe":1}"#.utf8)
        discord.sendPing(probe)
        #expect(await eventually(timeout: .seconds(2)) { discord.pongs.contains(probe) })

        // ...and stop() clears the activity once, then closes the connection.
        let framesBeforeStop = discord.receivedFrames.count
        let began = ContinuousClock.now
        await controller.stop()
        #expect(ContinuousClock.now - began < .seconds(2))
        #expect(await controller.snapshot == .idle)
        #expect(await eventually { discord.openConnectionCount == 0 })
        let farewell = Array(discord.receivedFrames.dropFirst(framesBeforeStop))
        #expect(farewell.map(\.opcode) == [.frame, .close])
        #expect(farewell.first.map { isClear($0.payload) } == true)
        // A stopped controller doesn't connect again.
        let connections = discord.connectionCount
        #expect(await stays(for: .milliseconds(300)) { discord.connectionCount == connections })
    }

    /// Whether `payload` is a SET_ACTIVITY that clears the activity.
    private func isClear(_ payload: Data) -> Bool {
        guard let command = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              command["cmd"] as? String == "SET_ACTIVITY",
              let arguments = command["args"] as? [String: Any]
        else { return false }
        return arguments["activity"] == nil
    }

    /// The `activity` of every SET_ACTIVITY the mock received, in order; `nil` for a clear.
    private func setActivities(_ discord: MockDiscordServer) -> [[String: Any]?] {
        discord.commands.compactMap { payload -> [String: Any]?? in
            guard let command = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  command["cmd"] as? String == "SET_ACTIVITY",
                  let arguments = command["args"] as? [String: Any]
            else { return nil }
            return .some(arguments["activity"] as? [String: Any])
        }
    }

    /// The `large_image` of an activity sent to the mock.
    private func largeImage(of activity: [String: Any]?) -> String? {
        (activity?["assets"] as? [String: Any])?["large_image"] as? String
    }
}

private extension MockDiscordServer {
    /// The user `MockDiscordServer()` answers the handshake with.
    static let defaultUser = DiscordUser(id: "1", username: "tester", globalName: "Tester")
}

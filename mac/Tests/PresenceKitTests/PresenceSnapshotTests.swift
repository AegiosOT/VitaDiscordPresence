import DiscordIPC
import Testing
import VitaKit
@testable import PresenceKit

@Suite struct PresenceSnapshotTests {
    @Test func idleIsTheStoppedState() {
        let idle = PresenceSnapshot.idle
        #expect(!idle.isRunning)
        #expect(idle.vita == .idle)
        #expect(idle.discord == .idle)
        #expect(idle.title == nil && idle.sessionStart == nil && idle.host == nil)
        #expect(idle.lastSuccess == nil && idle.publishedActivity == nil)
    }

    @Test func vitaSummaries() {
        #expect(VitaStatus.idle.summary == "Not running")
        #expect(VitaStatus.misconfigured("Enter your Vita's IP or MAC address").summary
            == "Enter your Vita's IP or MAC address")
        #expect(VitaStatus.resolving.summary == "Looking for your Vita\u{2026}")
        #expect(VitaStatus.connecting.summary == "Connecting to your Vita\u{2026}")
        #expect(VitaStatus.connected.summary == "Connected")
    }

    @Test(arguments: [
        VitaConnectionError.timedOut,
        .refused,
        .localNetworkDenied,
        .unreachable("EHOSTUNREACH"),
        .incompletePacket(byteCount: 0),
        .unresolvedAddress("Couldn't find a4:5e:60:01:02:03"),
    ])
    func failingVitaShowsTheErrorMessage(error: VitaConnectionError) {
        #expect(VitaStatus.failing(error, failures: 3).summary == error.userMessage)
    }

    @Test func discordSummaries() {
        #expect(DiscordStatus.idle.summary == "Not running")
        #expect(DiscordStatus.connecting.summary == "Connecting to Discord\u{2026}")
        #expect(DiscordStatus.connected(testUser).summary == "Connected as Tester")
        let noDisplayName = DiscordUser(id: "7", username: "plainname", globalName: nil)
        #expect(DiscordStatus.connected(noDisplayName).summary == "Connected as plainname")
    }

    @Test(arguments: [
        DiscordIPCError.discordNotRunning,
        .invalidClientID,
        .rpcError(code: 4000, message: "child \"activity\" fails"),
        .closedByDiscord(code: 1000, message: "bye"),
        .timedOut,
    ])
    func unavailableDiscordShowsTheErrorMessage(error: DiscordIPCError) {
        #expect(DiscordStatus.unavailable(error).summary == error.userMessage)
    }
}

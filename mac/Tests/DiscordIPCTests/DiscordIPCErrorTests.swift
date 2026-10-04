import Testing
@testable import DiscordIPC

@Suite struct DiscordIPCErrorTests {
    @Test(arguments: [
        (DiscordIPCError.discordNotRunning, "Discord isn't running"),
        (.invalidClientID, "Invalid Discord application ID"),
        (.closedByDiscord(code: 4002, message: "Rate limited"), "Discord closed the connection (4002)"),
        (.rpcError(code: 4000, message: "Invalid payload"), "Discord rejected the update: Invalid payload"),
        (.rpcError(code: 5011, message: ""), "Discord rejected the update (5011)"),
        (.timedOut, "Discord didn't respond"),
        (.notConnected, "Not connected to Discord"),
        (.protocolViolation("Unknown opcode 9"), "Discord connection error"),
        (.io("Connection reset by peer"), "Discord connection error"),
    ])
    func userMessage(error: DiscordIPCError, expected: String) {
        #expect(error.userMessage == expected)
    }
}

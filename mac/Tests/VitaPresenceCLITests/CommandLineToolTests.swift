import Darwin
import Foundation
import PresenceKit
import Testing
import TestSupport
import VitaKit
@testable import VitaPresenceCLI

@Suite struct CommandLineToolTests {
    @Test func versionMatchesTheApp() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // VitaPresenceCLITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // mac
            .appendingPathComponent("Resources/Info.plist")
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil)
        let version = try #require((info as? [String: Any])?["CFBundleShortVersionString"] as? String)
        #expect(CommandLineTool.version == version)
    }
}

/// Runs the built `vitapresence-cli` in a child process against the loopback mock Vita and a mock Discord
/// socket under /tmp, and checks how it ends. Every run passes `--no-artwork`, so nothing is looked up online,
/// and an address, so nothing is scanned.
@Suite struct RunningTheToolTests {
    private static let clientID = "123456789012345678"
    private static let game = VitaTitle(index: 2, titleID: "PCSE00120", name: "Persona 4 Golden")

    @Test(arguments: [SIGINT, SIGTERM])
    func aSignalClearsThePresenceAndExits(signal: Int32) async throws {
        let vita = try await MockVitaServer(behavior: .packet(Self.game))
        defer { vita.stop() }
        let discord = try MockDiscordServer()
        defer { discord.stop() }
        let tool = try RunningTool(arguments: arguments(vita: vita, discord: discord))
        defer { tool.stop() }
        #expect(await eventually { setActivities(discord).contains(Self.game.name) })

        tool.send(signal)

        try #require(await tool.waitForExit())
        #expect(tool.process.terminationReason == .exit)
        #expect(tool.process.terminationStatus == EXIT_SUCCESS)
        #expect(await eventually { discord.receivedFrames.last?.opcode == .close })
        #expect(setActivities(discord).last == .some(Self.game.name))
        #expect(setActivities(discord).filter { $0 == nil }.isEmpty, "closing drops the presence; an empty activity would show the application's name")
        let output = tool.outputLines()
        #expect(output.dropLast().last?.hasSuffix("Stopping (press Ctrl-C again to quit immediately)…") == true)
        #expect(output.last?.hasSuffix("Stopped.") == true)
        #expect(tool.errorText() == "")
    }

    @Test func shutdownFinishesWhenNothingReadsTheOutput() async throws {
        // As with `vitapresence-cli … | tee log`, where Ctrl-C ends tee as well.
        let vita = try await MockVitaServer(behavior: .packet(Self.game))
        defer { vita.stop() }
        let discord = try MockDiscordServer()
        defer { discord.stop() }
        let tool = try RunningTool(arguments: arguments(vita: vita, discord: discord))
        defer { tool.stop() }
        #expect(await eventually { setActivities(discord).contains(Self.game.name) })

        try tool.closeOutput()
        tool.send(SIGINT)

        try #require(await tool.waitForExit())
        #expect(tool.process.terminationReason == .exit, "not killed by SIGPIPE")
        #expect(tool.process.terminationStatus == EXIT_SUCCESS)
        #expect(await eventually { discord.receivedFrames.last?.opcode == .close })
        #expect(setActivities(discord).last == .some(Self.game.name))
    }

    @Test func withoutAClientIDTheBuiltInApplicationIsUsed() async throws {
        let vita = try await MockVitaServer(behavior: .packet(Self.game))
        defer { vita.stop() }
        let discord = try MockDiscordServer()
        defer { discord.stop() }
        let tool = try RunningTool(arguments: [
            "127.0.0.1", "--port", String(vita.port), "--no-artwork", "--interval", "3",
            "--discord-socket", discord.socketPath,
        ])
        defer { tool.stop() }
        #expect(await eventually { setActivities(discord).contains(Self.game.name) })

        tool.send(SIGINT)

        try #require(await tool.waitForExit())
        #expect(tool.process.terminationStatus == EXIT_SUCCESS)
        let handshake = try #require(discord.handshakes.first)
        let json = try #require(try JSONSerialization.jsonObject(with: handshake) as? [String: Any])
        #expect(json["client_id"] as? String == PresenceSettings.defaultClientID)
        let output = tool.outputLines()
        #expect(output.first?.contains(
            "Vita 127.0.0.1 port \(vita.port), Discord application built-in (\(PresenceSettings.defaultClientID)), "
                + "polling every 3 s, no game artwork"
        ) == true)
        let status = "Vita: \(VitaStatus.connected.summary) at 127.0.0.1 - Persona 4 Golden"
        #expect(output.contains { $0.contains(status) })
    }

    @Test func unusableSettingsAreAUsageError() async throws {
        let tool = try RunningTool(arguments: ["--address", "127.0.0.1", "--client-id", "12345"])
        defer { tool.stop() }

        try #require(await tool.waitForExit())
        #expect(tool.process.terminationReason == .exit)
        #expect(tool.process.terminationStatus == EX_USAGE)
        #expect(tool.outputLines().isEmpty)
        let errors = tool.errorText()
        #expect(errors.contains(PresenceSettings.Issue.invalidClientID.message))
        #expect(errors.contains(Usage.hint))
    }

    @Test func badArgumentsAreAUsageError() async throws {
        let tool = try RunningTool(arguments: ["127.0.0.1", "123456789012345678", "extra"])
        defer { tool.stop() }

        try #require(await tool.waitForExit())
        #expect(tool.process.terminationReason == .exit)
        #expect(tool.process.terminationStatus == EX_USAGE)
        #expect(tool.outputLines().isEmpty)
        #expect(tool.errorText() == "vitapresence-cli: unexpected argument 'extra'\n\(Usage.hint)\n")
    }

    private func arguments(vita: MockVitaServer, discord: MockDiscordServer) -> [String] {
        [
            "--address", "127.0.0.1", "--port", String(vita.port), "--client-id", Self.clientID,
            "--no-artwork", "--interval", "3", "--discord-socket", discord.socketPath,
        ]
    }

    /// The game every SET_ACTIVITY `discord` received shows, in order: the activity's name (the bold title), or
    /// its details when it has no name. `nil` for one that clears the activity.
    private func setActivities(_ discord: MockDiscordServer) -> [String?] {
        discord.commands.compactMap { payload -> String?? in
            guard let command = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  command["cmd"] as? String == "SET_ACTIVITY",
                  let arguments = command["args"] as? [String: Any]
            else { return nil }
            guard let activity = arguments["activity"] as? [String: Any] else { return .some(nil) }
            return .some(activity["name"] as? String ?? activity["details"] as? String)
        }
    }
}

/// `vitapresence-cli` in a child process, with its standard output and standard error captured.
private final class RunningTool {
    let process = Process()
    private let output = Pipe()
    private let errors = Pipe()

    init(arguments: [String]) throws {
        // SwiftPM builds the executable next to the test bundle.
        let executable = Bundle(for: RunningTool.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("vitapresence-cli")
        try #require(FileManager.default.isExecutableFile(atPath: executable.path), "\(executable.path) is missing")
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
    }

    func send(_ signal: Int32) {
        kill(process.processIdentifier, signal)
    }

    /// Waits until the process has exited, and returns whether it did within `timeout`.
    func waitForExit(timeout: Duration = .seconds(5)) async -> Bool {
        await eventually(timeout: timeout) { !self.process.isRunning }
    }

    /// Closes the reading end of standard output, as if whatever read it had quit.
    func closeOutput() throws {
        try output.fileHandleForReading.close()
    }

    /// Everything written to standard output, as lines. Call it once the process has exited.
    func outputLines() -> [String] {
        String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
    }

    /// Everything written to standard error. Call it once the process has exited.
    func errorText() -> String {
        String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// Kills the process if it is still running, so a failed test leaves nothing behind.
    func stop() {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }
}

/// Polls `condition` until it holds or `timeout` passes, and returns whether it held.
private func eventually(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

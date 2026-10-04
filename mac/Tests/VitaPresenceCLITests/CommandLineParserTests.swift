import PresenceKit
import Testing
import VitaKit
@testable import VitaPresenceCLI

private func run(_ arguments: [String]) throws -> RunOptions {
    let command = try CommandLineParser.parse(arguments)
    guard case .run(let options) = command else {
        Issue.record("expected .run, got \(command)")
        return RunOptions()
    }
    return options
}

private func usageError(_ arguments: [String]) -> UsageError? {
    do {
        _ = try CommandLineParser.parse(arguments)
        return nil
    } catch {
        return error
    }
}

@Suite struct CommandLineParserTests {
    @Test func noArgumentsShowsTheSynopsis() {
        #expect(usageError([]) == .noArguments)
    }

    @Test func helpAndVersion() throws {
        #expect(try CommandLineParser.parse(["--help"]) == .help)
        #expect(try CommandLineParser.parse(["-h"]) == .help)
        #expect(try CommandLineParser.parse(["--version"]) == .version)
        // They take effect as soon as they are reached, even with other options around them.
        #expect(try CommandLineParser.parse(["--address", "1.2.3.4", "--help", "--bogus"]) == .help)
        #expect(try CommandLineParser.parse(["--version", "--help"]) == .version)
        #expect(try CommandLineParser.parse(["1.2.3.4", "5", "6", "--help"]) == .help)
        #expect(usageError(["--bogus", "--help"]) == .invalid("unknown option '--bogus'"))
    }

    @Test func namedForm() throws {
        let options = try run([
            "--address", "192.168.1.20", "--client-id", "123456789012345678", "--state", "Handheld mode",
            "--interval", "4.5", "--large-image", "https://example.com/vita.png", "--no-elapsed", "--hide-livearea",
            "--port", "40000", "--discord-socket", "/tmp/vp/discord-ipc-0", "--verbose",
        ])
        #expect(options.settings == PresenceSettings(
            address: "192.168.1.20",
            clientID: "123456789012345678",
            stateText: "Handheld mode",
            largeImageKey: "https://example.com/vita.png",
            pollInterval: 4.5,
            showElapsedTime: false,
            showLiveArea: false
        ))
        #expect(options.port == 40000)
        #expect(options.discordSocket == "/tmp/vp/discord-ipc-0")
        #expect(options.verbose)
    }

    @Test func defaults() throws {
        let options = try run(["--address", "a4:5e:60:01:02:03", "--client-id", "123456789012345678"])
        #expect(options.settings == PresenceSettings(address: "a4:5e:60:01:02:03", clientID: "123456789012345678"))
        #expect(options.settings.pollInterval == PresenceSettings.defaultPollInterval)
        #expect(options.settings.showElapsedTime)
        #expect(options.settings.showLiveArea)
        #expect(options.port == VitaPacket.port)
        #expect(options.port == 51966)
        #expect(options.discordSocket == nil)
        #expect(!options.verbose)
    }

    @Test func attachedValues() throws {
        let options = try run([
            "--address=10.0.0.2", "--client-id=123456789012345678", "--state=--busy--", "--interval=300", "--port=1",
            "--large-image=",
        ])
        #expect(options.settings.address == "10.0.0.2")
        #expect(options.settings.stateText == "--busy--")
        #expect(options.settings.pollInterval == 300)
        #expect(options.settings.largeImageKey == "")
        #expect(options.port == 1)
        // Only the first "=" separates the value.
        #expect(try run(["--state=a=b"]).settings.stateText == "a=b")
    }

    @Test func valuesMayStartWithASingleDashButNotTwo() throws {
        #expect(try run(["--state", "-"]).settings.stateText == "-")
        #expect(try run(["--state", "-h"]).settings.stateText == "-h")
        #expect(try run(["--state", ""]).settings.stateText == "")
        #expect(usageError(["--state", "--verbose"]) == .invalid("--state needs a value"))
        #expect(usageError(["--address"]) == .invalid("--address needs a value"))
        #expect(usageError(["--address", "--client-id", "1"]) == .invalid("--address needs a value"))
    }

    @Test func positionalForm() throws {
        let options = try run(["192.168.1.20", "123456789012345678"])
        #expect(options.settings.address == "192.168.1.20")
        #expect(options.settings.clientID == "123456789012345678")
        // Options can be mixed in anywhere.
        let mixed = try run(["--verbose", "192.168.1.20", "--state", "Hi", "123456789012345678", "--port", "2"])
        #expect(mixed.settings.address == "192.168.1.20")
        #expect(mixed.settings.clientID == "123456789012345678")
        #expect(mixed.settings.stateText == "Hi")
        #expect(mixed.verbose)
        #expect(mixed.port == 2)
        // A lone "-" is an argument, not an option.
        #expect(try run(["-", "1"]).settings.address == "-")
    }

    @Test func positionalErrors() {
        #expect(usageError(["192.168.1.20"]) == .invalid("missing <client-id> after '192.168.1.20'"))
        #expect(usageError(["a", "b", "c"]) == .invalid("unexpected argument 'c'"))
        #expect(usageError(["--address", "1.2.3.4", "1.2.3.4", "1"])
            == .invalid("--address can't be combined with a positional address and client ID"))
        #expect(usageError(["1.2.3.4", "1", "--client-id", "2"])
            == .invalid("--client-id can't be combined with a positional address and client ID"))
    }

    @Test func repeatedOptionsKeepTheLastValue() throws {
        let options = try run(["--address", "1.1.1.1", "--address", "2.2.2.2", "--port", "5", "--port", "6"])
        #expect(options.settings.address == "2.2.2.2")
        #expect(options.port == 6)
    }

    @Test func unknownOptions() {
        #expect(usageError(["--bogus"]) == .invalid("unknown option '--bogus'"))
        #expect(usageError(["--bogus=1"]) == .invalid("unknown option '--bogus'"))
        #expect(usageError(["-x"]) == .invalid("unknown option '-x'"))
        #expect(usageError(["-v"]) == .invalid("unknown option '-v'"))
        #expect(usageError(["--"]) == .invalid("unknown option '--'"))
        #expect(usageError(["--ADDRESS", "1.2.3.4"]) == .invalid("unknown option '--ADDRESS'"))
    }

    @Test func flagsRejectValues() {
        for flag in ["--no-elapsed", "--hide-livearea", "--verbose", "--scan", "--help", "--version"] {
            #expect(usageError(["\(flag)=1"]) == .invalid("\(flag) doesn't take a value"))
        }
    }

    @Test(arguments: ["3", "300", "10", "4.5", "3.0", "1e2"])
    func validIntervals(_ text: String) throws {
        #expect(try run(["--interval", text]).settings.pollInterval == Double(text))
    }

    @Test(arguments: ["2.99", "300.5", "0", "-5", "abc", "", "nan", "inf", "-inf", "10s", " 10"])
    func invalidIntervals(_ text: String) {
        #expect(usageError(["--interval=\(text)"])
            == .invalid("--interval must be a number of seconds from 3 to 300, not '\(text)'"))
    }

    @Test(arguments: ["0", "65536", "-1", "abc", "", "1.5", "99999999999999999999"])
    func invalidPorts(_ text: String) {
        #expect(usageError(["--port=\(text)"]) == .invalid("--port must be a number from 1 to 65535, not '\(text)'"))
    }

    @Test func validPorts() throws {
        #expect(try run(["--port", "1"]).port == 1)
        #expect(try run(["--port", "65535"]).port == 65535)
        #expect(try run(["--port", "+8080"]).port == 8080)
    }

    @Test func discordSocketPath() throws {
        let fits = "/tmp/" + String(repeating: "x", count: 98)  // 103 bytes
        #expect(try run(["--discord-socket", fits]).discordSocket == fits)
        #expect(usageError(["--discord-socket", fits + "x"])
            == .invalid("--discord-socket path is too long (Unix socket paths must be shorter than 104 bytes)"))
        #expect(usageError(["--discord-socket", ""]) == .invalid("--discord-socket needs a path"))
        #expect(usageError(["--discord-socket="]) == .invalid("--discord-socket needs a path"))
        // The limit counts UTF-8 bytes, not characters.
        let wide = "/tmp/" + String(repeating: "é", count: 50)  // 105 bytes
        #expect(usageError(["--discord-socket", wide])
            == .invalid("--discord-socket path is too long (Unix socket paths must be shorter than 104 bytes)"))
    }

    @Test func scan() throws {
        #expect(try CommandLineParser.parse(["--scan"]) == .scan(port: 51966))
        #expect(try CommandLineParser.parse(["--scan", "--port", "40000"]) == .scan(port: 40000))
        #expect(try CommandLineParser.parse(["--port=7", "--scan"]) == .scan(port: 7))
    }

    @Test func scanRejectsRunOptions() {
        let cases: [[String]: String] = [
            ["--scan", "--address", "1.2.3.4"]: "--address",
            ["--scan", "--client-id", "1"]: "--client-id",
            ["--scan", "--state", "x"]: "--state",
            ["--scan", "--interval", "5"]: "--interval",
            ["--scan", "--large-image", "k"]: "--large-image",
            ["--scan", "--no-elapsed"]: "--no-elapsed",
            ["--scan", "--hide-livearea"]: "--hide-livearea",
            ["--scan", "--discord-socket", "/tmp/s"]: "--discord-socket",
            ["--verbose", "--scan"]: "--verbose",
        ]
        for (arguments, option) in cases {
            #expect(usageError(arguments) == .invalid("--scan can't be combined with \(option)"), "\(arguments)")
        }
        #expect(usageError(["--scan", "192.168.1.20"]) == .invalid("unexpected argument '192.168.1.20'"))
    }

    @Test func settingsAreNotValidatedByTheParser() throws {
        // Address and client ID problems are reported from PresenceSettings.issues, after parsing.
        let options = try run(["--verbose"])
        #expect(options.settings.address.isEmpty)
        #expect(options.settings.clientID.isEmpty)
        #expect(try run(["--address", "not an address", "--client-id", "12"]).settings.address == "not an address")
    }
}

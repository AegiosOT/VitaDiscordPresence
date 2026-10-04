import Darwin
import PresenceKit
import VitaKit

/// What the command line asks for.
enum Command: Equatable {
    /// Poll the Vita and keep Discord's activity in sync until SIGINT or SIGTERM.
    case run(RunOptions)
    /// List the Vitas on the local network that answer on `port`.
    case scan(port: UInt16)
    case help
    case version
}

/// What `run` needs: the presence settings plus the options only the CLI has.
struct RunOptions: Equatable {
    var settings = PresenceSettings()
    /// TCP port of the Vita plugin.
    var port = VitaPacket.port
    /// The only Discord IPC socket to connect to; `nil` tries the usual locations.
    var discordSocket: String?
    /// Print every snapshot, not only the ones that change the status line.
    var verbose = false
}

/// Why the arguments can't be used.
enum UsageError: Error, Equatable {
    /// No arguments at all: show the synopsis.
    case noArguments
    /// A user-facing explanation, such as "unknown option '--foo'".
    case invalid(String)
}

/// Hand-written parser for the options in `Usage.help`.
///
/// A value follows its option (`--state Busy`) or is attached with `=` (`--state=--busy--`). A separate value
/// can't start with `--`, so a forgotten value is reported instead of swallowing the next option. A repeated
/// option keeps its last value. `--help` and `--version` take effect as soon as they are reached. Only the
/// syntax, the numeric ranges and the socket path length are checked here; the address and client ID are
/// validated by `PresenceSettings.issues`.
enum CommandLineParser {
    static func parse(_ arguments: [String]) throws(UsageError) -> Command {
        guard !arguments.isEmpty else { throw .noArguments }
        var options = RunOptions()
        var scan = false
        var given: [Option] = []
        var positionals: [String] = []
        var remaining = arguments[...]

        while let argument = remaining.popFirst() {
            if argument == "-h" { return .help }
            guard argument.hasPrefix("--") else {
                if argument.hasPrefix("-"), argument != "-" { throw .invalid("unknown option '\(argument)'") }
                positionals.append(argument)
                continue
            }
            let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            guard let option = Option(rawValue: name) else { throw .invalid("unknown option '\(name)'") }
            let attached = parts.count == 2 ? String(parts[1]) : nil
            let value: String
            if option.takesValue {
                if let attached {
                    value = attached
                } else if let next = remaining.first, !next.hasPrefix("--") {
                    value = next
                    remaining.removeFirst()
                } else {
                    throw .invalid("\(name) needs a value")
                }
            } else {
                guard attached == nil else { throw .invalid("\(name) doesn't take a value") }
                value = ""
            }

            switch option {
            case .help: return .help
            case .version: return .version
            case .scan: scan = true
            case .address: options.settings.address = value
            case .clientID: options.settings.clientID = value
            case .state: options.settings.stateText = value
            case .largeImage: options.settings.largeImageKey = value
            case .interval: options.settings.pollInterval = try pollInterval(from: value)
            case .noElapsed: options.settings.showElapsedTime = false
            case .hideLiveArea: options.settings.showLiveArea = false
            case .port: options.port = try port(from: value)
            case .discordSocket: options.discordSocket = try socketPath(from: value)
            case .verbose: options.verbose = true
            }
            given.append(option)
        }

        if scan {
            if let other = given.first(where: { $0 != .scan && $0 != .port }) {
                throw .invalid("--scan can't be combined with \(other.rawValue)")
            }
            if let extra = positionals.first { throw .invalid("unexpected argument '\(extra)'") }
            return .scan(port: options.port)
        }
        if !positionals.isEmpty {
            if let other = given.first(where: { $0 == .address || $0 == .clientID }) {
                throw .invalid("\(other.rawValue) can't be combined with a positional address and client ID")
            }
            guard positionals.count >= 2 else { throw .invalid("missing <client-id> after '\(positionals[0])'") }
            guard positionals.count == 2 else { throw .invalid("unexpected argument '\(positionals[2])'") }
            options.settings.address = positionals[0]
            options.settings.clientID = positionals[1]
        }
        return .run(options)
    }

    private static func pollInterval(from text: String) throws(UsageError) -> Double {
        let range = PresenceSettings.pollIntervalRange
        guard let seconds = Double(text), range.contains(seconds) else {
            throw .invalid(
                "--interval must be a number of seconds from \(Usage.seconds(range.lowerBound)) "
                    + "to \(Usage.seconds(range.upperBound)), not '\(text)'"
            )
        }
        return seconds
    }

    private static func port(from text: String) throws(UsageError) -> UInt16 {
        guard let port = UInt16(text), port > 0 else {
            throw .invalid("--port must be a number from 1 to 65535, not '\(text)'")
        }
        return port
    }

    private static func socketPath(from text: String) throws(UsageError) -> String {
        // The path must fit in sockaddr_un.sun_path together with its terminating NUL.
        let limit = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        guard !text.isEmpty else { throw .invalid("--discord-socket needs a path") }
        guard text.utf8.count < limit else {
            throw .invalid("--discord-socket path is too long (Unix socket paths must be shorter than \(limit) bytes)")
        }
        return text
    }
}

/// Every long option, spelled as on the command line.
private enum Option: String {
    case address = "--address"
    case clientID = "--client-id"
    case state = "--state"
    case interval = "--interval"
    case largeImage = "--large-image"
    case noElapsed = "--no-elapsed"
    case hideLiveArea = "--hide-livearea"
    case port = "--port"
    case discordSocket = "--discord-socket"
    case verbose = "--verbose"
    case scan = "--scan"
    case help = "--help"
    case version = "--version"

    var takesValue: Bool {
        switch self {
        case .address, .clientID, .state, .interval, .largeImage, .port, .discordSocket: true
        case .noElapsed, .hideLiveArea, .verbose, .scan, .help, .version: false
        }
    }
}

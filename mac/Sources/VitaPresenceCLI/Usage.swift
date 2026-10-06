import PresenceKit
import VitaKit

/// Help, usage and hint texts, wrapped for an 80-column terminal.
enum Usage {
    static let synopsis = """
        Usage: \(CommandLineTool.name) [options]
               \(CommandLineTool.name) <ip|mac> [<client-id>] [options]
               \(CommandLineTool.name) --scan [--port <n>]
               \(CommandLineTool.name) --help | --version
        """

    /// Printed after every usage error.
    static let hint = "Run '\(CommandLineTool.name) --help' for all options."

    static var help: String {
        let range = PresenceSettings.pollIntervalRange
        let interval = "\(seconds(range.lowerBound)) to \(seconds(range.upperBound))"
        let defaultInterval = seconds(PresenceSettings.defaultPollInterval)
        return """
            \(CommandLineTool.name) \(CommandLineTool.version): shows your PS Vita game as your Discord activity.

            \(synopsis)

            Options:
              --address <ip|mac|auto>  The Vita's IPv4 or MAC address (default: auto, which
                                       finds the Vita on the local network)
              --client-id <id>         Your own Discord application ID (default: the
                                       built-in application)
              --state <text>           Second line under the game name
              --interval <seconds>     Time between polls, \(interval) (default \(defaultInterval))
              --large-image <key|url>  Custom image instead of the game artwork: an art
                                       asset key of your own application, or an https URL
              --no-artwork             Don't look up or show the game artwork
              --no-elapsed             Don't show the elapsed time
              --hide-livearea          Show nothing while the Vita is in the LiveArea
              --verbose                Print every status update, not only changes
              --scan                   Find Vitas on the local network
              -h, --help               Show this help
              --version                Show the version

            Advanced and testing:
              --port <n>               Port of the Vita plugin (default \(VitaPacket.port))
              --discord-socket <path>  Connect only to this Discord IPC socket

            Without options, the Vita is found on the local network and the built-in
            Discord application is used. The Vita needs the VitaPresence plugin in the
            *KERNEL section of ux0:tai/config.txt, and the Discord desktop app must be
            running on this Mac. Press Ctrl-C to clear the presence and quit.

            To find the game artwork, this Mac looks up the running game on
            store.playstation.com, GitHub (HexFlow-Covers) and NeoVitaDB, and Discord
            loads the picture from there. --no-artwork turns this off.

            Exit status: 0 success, 1 runtime failure, 64 usage error.
            """
    }

    /// Shown when macOS blocks the connection to the Vita.
    static let localNetworkHint = """
        Hint: macOS blocked Local Network access for the app running \(CommandLineTool.name).
        Terminal is always allowed; turn other terminal apps on in System Settings >
        Privacy & Security > Local Network.
        """

    /// `10` or `4.5`.
    static func seconds(_ value: Double) -> String {
        let text = String(value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}

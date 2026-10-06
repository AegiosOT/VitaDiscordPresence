import ArtworkKit
import DiscordIPC
import Foundation
import PresenceKit
import VitaKit

/// The default command: runs a `PresenceController` and prints a line for every status change until SIGINT
/// or SIGTERM, then stops it, which clears the presence.
enum RunCommand {
    /// Exit status 0 after a signal, 64 for unusable settings, 1 if the controller stops publishing.
    static func run(_ options: RunOptions) async -> Int32 {
        let issues = options.settings.issues
        guard issues.isEmpty else {
            for issue in issues {
                Console.error("\(CommandLineTool.name): \(issue.message)")
            }
            Console.error(Usage.hint)
            return EX_USAGE
        }

        let shutdown = ShutdownSignals()
        let controller = makeController(options)
        let formatter = StatusFormatter()
        Console.out("\(formatter.timestamp(Date())) \(formatter.startup(options))")
        await controller.start(with: options.settings)

        let snapshotsEnded = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await shutdown.wait()
                return false
            }
            group.addTask {
                var printer = StatusPrinter(verbose: options.verbose, formatter: formatter)
                for await snapshot in controller.snapshots {
                    for line in printer.lines(for: snapshot, at: Date()) {
                        Console.out(line)
                    }
                }
                return true
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        Console.out("\(formatter.timestamp(Date())) Stopping (press Ctrl-C again to quit immediately)…")
        await controller.stop()
        guard !snapshotsEnded else {
            Console.error("\(CommandLineTool.name): the controller stopped publishing its status")
            return EXIT_FAILURE
        }
        Console.out("\(formatter.timestamp(Date())) Stopped.")
        return EXIT_SUCCESS
    }

    private static func makeController(_ options: RunOptions) -> PresenceController {
        let discord = options.discordSocket.map { path in DiscordIPCClient(socketPaths: { [path] }) }
        let artwork: any ArtworkResolving = options.settings.showGameArtwork ? ArtworkResolver() : NoArtwork()
        return PresenceController(
            fetcher: VitaClient(port: options.port),
            // The CLI doesn't remember where the Vita answered, so automatic discovery starts with a scan.
            // Artwork lookups are cached in the same directory as the app.
            resolver: VitaResolver(scanner: ScanCommand.scanner(port: options.port), knownHost: nil),
            discord: discord ?? DiscordIPCClient(),
            artwork: artwork
        )
    }
}

/// With `--no-artwork`, nothing is looked up at all.
private struct NoArtwork: ArtworkResolving {
    func artwork(for title: VitaTitle) async -> URL? {
        nil
    }
}

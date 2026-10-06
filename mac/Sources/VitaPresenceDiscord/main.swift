import Darwin
import DiscordIPC
import Foundation

/// Speaks Discord IPC for the menu-bar app. The app stays running; this process exits when the Vita
/// disconnects, which is what makes Discord drop "Playing VitaPresence".
@main
struct DiscordHelperMain {
    static func main() async {
        // A broken pipe means the menu-bar app is gone. Exit instead of being killed mid-update.
        signal(SIGPIPE, SIG_IGN)
        setvbuf(stdout, nil, _IOLBF, 0)
        let session = Session()
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                if line.isEmpty { continue }
                let shouldExit = await session.handle(line)
                if shouldExit { return }
            }
        } catch {
            // Standard input closed.
        }
        await session.closeAndExit()
    }
}

private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}()

private let decoder = JSONDecoder()

private func emit(_ event: DiscordHelperEvent) {
    guard var line = try? encoder.encode(event) else { return }
    line.append(0x0A)
    do {
        try FileHandle.standardOutput.write(contentsOf: line)
    } catch {
        exit(EXIT_SUCCESS)
    }
}

/// The helper's Discord connection. One command is handled at a time, in the order it arrives.
private actor Session {
    private var client: DiscordIPCClient?

    /// Handles one command line. Returns `true` when the process should exit.
    func handle(_ line: String) async -> Bool {
        guard let command = try? decoder.decode(DiscordHelperCommand.self, from: Data(line.utf8)) else {
            emit(.failure(.protocolViolation("unreadable command")))
            return false
        }
        switch command.cmd {
        case "connect":
            return await connect(command)
        case "setActivity":
            await update(command.activity)
            return false
        case "quit":
            await closeAndExit()
            return true
        default:
            emit(.failure(.protocolViolation("unknown command \(command.cmd)")))
            return false
        }
    }

    func closeAndExit() async {
        if let client {
            self.client = nil
            await client.disconnect()
        }
    }

    /// Handshakes, then publishes `activity` before reporting ready. Returns `true` when this process should
    /// exit: a failed activity closes the socket and leaves, so Discord does not keep the application's name.
    private func connect(_ command: DiscordHelperCommand) async -> Bool {
        if let client {
            await client.disconnect()
            self.client = nil
        }
        let socket = command.socket
        let discord = DiscordIPCClient(socketPaths: {
            if let socket { return [socket] }
            return DiscordIPCPath.candidates()
        })
        client = discord
        do {
            let user = try await discord.connect(clientID: command.clientID ?? "")
            if let activity = command.activity {
                do {
                    try await discord.setActivity(activity)
                } catch let error as DiscordIPCError where isRefusal(error) {
                    // Discord refused this payload and left the socket up. The menu-bar app retries.
                } catch {
                    // Anything else means the socket is dead. Leave, so the application's name does not stay.
                    await dropAndLeave()
                    emit(.failure(error as? DiscordIPCError ?? .io(String(describing: error))))
                    return true
                }
            }
            emit(.ready(user))
            return false
        } catch let error as DiscordIPCError {
            await dropAndLeave()
            emit(.failure(error))
            return false
        } catch {
            await dropAndLeave()
            emit(.failure(.io(String(describing: error))))
            return false
        }
    }

    private func isRefusal(_ error: DiscordIPCError) -> Bool {
        if case .rpcError = error { return true }
        return false
    }

    /// Closes the socket without a null activity. The process exits only when the caller says so.
    private func dropAndLeave() async {
        if let client {
            self.client = nil
            await client.disconnect()
        }
    }

    private func update(_ activity: DiscordActivity?) async {
        guard let client else {
            emit(.failure(.notConnected))
            return
        }
        do {
            try await client.setActivity(activity)
            emit(.activity())
        } catch let error as DiscordIPCError {
            emit(.failure(error))
        } catch {
            emit(.failure(.io(String(describing: error))))
        }
    }
}

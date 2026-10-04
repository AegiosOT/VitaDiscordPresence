/// Why talking to Discord failed.
public enum DiscordIPCError: Error, Equatable, Sendable {
    /// No candidate socket accepted a connection: the Discord desktop app isn't running.
    case discordNotRunning
    /// Discord closed the connection during the handshake with code 4000: the application (client) ID
    /// doesn't exist.
    case invalidClientID
    /// Discord sent CLOSE (or the socket ended) with this code and message.
    case closedByDiscord(code: Int, message: String)
    /// Discord answered a command with `evt: "ERROR"`. For SET_ACTIVITY this is permanent for that payload
    /// (for example a field outside its length limits); don't resend the same payload.
    case rpcError(code: Int, message: String)
    /// No READY or no reply arrived in time.
    case timedOut
    /// The operation needs a connection that is ready (handshake done, READY received).
    case notConnected
    /// Malformed or unexpected data: unknown opcode, oversized frame, or JSON that can't be decoded.
    case protocolViolation(String)
    /// Socket-level failure, with a diagnostic description.
    case io(String)

    /// A short, user-facing explanation for a status line, such as
    /// "Discord isn't running" or "Invalid Discord application ID".
    public var userMessage: String {
        switch self {
        case .discordNotRunning:
            "Discord isn't running"
        case .invalidClientID:
            "Invalid Discord application ID"
        case .closedByDiscord(let code, _):
            "Discord closed the connection (\(code))"
        case .rpcError(let code, let message):
            message.isEmpty ? "Discord rejected the update (\(code))" : "Discord rejected the update: \(message)"
        case .timedOut:
            "Discord didn't respond"
        case .notConnected:
            "Not connected to Discord"
        case .protocolViolation, .io:
            "Discord connection error"
        }
    }
}

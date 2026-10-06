import DiscordIPC
import Foundation
import VitaKit

/// A complete picture of the controller's state, published after every change.
public struct PresenceSnapshot: Sendable, Equatable {
    /// `true` between `start` and `stop`.
    public var isRunning: Bool
    public var vita: VitaStatus
    public var discord: DiscordStatus
    /// The last title reported by the Vita. Becomes `nil` once the presence is cleared after repeated
    /// failures, and on stop.
    public var title: VitaTitle?
    /// When the current title session (game or LiveArea visit) started; drives "elapsed".
    public var sessionStart: Date?
    /// The IPv4 address currently being polled, once known.
    public var host: String?
    /// When the Vita last answered successfully.
    public var lastSuccess: Date?
    /// The activity last accepted by Discord on the current connection (`nil` when cleared or unknown).
    public var publishedActivity: DiscordActivity?
    /// The artwork found for `title` (`nil` while looking it up, when there is none, or when artwork is off).
    public var artwork: URL?

    public init(
        isRunning: Bool = false,
        vita: VitaStatus = .idle,
        discord: DiscordStatus = .idle,
        title: VitaTitle? = nil,
        sessionStart: Date? = nil,
        host: String? = nil,
        lastSuccess: Date? = nil,
        publishedActivity: DiscordActivity? = nil,
        artwork: URL? = nil
    ) {
        self.isRunning = isRunning
        self.vita = vita
        self.discord = discord
        self.title = title
        self.sessionStart = sessionStart
        self.host = host
        self.lastSuccess = lastSuccess
        self.publishedActivity = publishedActivity
        self.artwork = artwork
    }

    /// The stopped state.
    public static let idle = PresenceSnapshot()
}

/// The Vita side of the connection.
public enum VitaStatus: Sendable, Equatable {
    /// Not running.
    case idle
    /// The settings can't be used; carries the first issue's message.
    case misconfigured(String)
    /// Looking for the Vita: automatic discovery, or resolving a MAC address (ARP lookup or LAN scan).
    case resolving
    /// First poll in progress.
    case connecting
    /// The last poll succeeded.
    case connected
    /// The last poll failed; `failures` counts consecutive failures.
    case failing(VitaConnectionError, failures: Int)

    /// Short status line, such as "Connected", "Looking for your Vita…" or the error's `userMessage`.
    public var summary: String {
        switch self {
        case .idle: "Not running"
        case .misconfigured(let message): message
        case .resolving: "Looking for your Vita…"
        case .connecting: "Connecting to your Vita…"
        case .connected: "Connected"
        case .failing(let error, _): error.userMessage
        }
    }
}

/// The Discord side of the connection.
public enum DiscordStatus: Sendable, Equatable {
    /// Not running.
    case idle
    /// Connecting or waiting for READY.
    case connecting
    /// READY received.
    case connected(DiscordUser)
    /// Not connected (Discord closed, invalid client ID, …) or the last update was rejected.
    case unavailable(DiscordIPCError)

    /// Short status line, such as "Connected as Alex" or the error's `userMessage`.
    public var summary: String {
        switch self {
        case .idle: "Not running"
        case .connecting: "Connecting to Discord…"
        case .connected(let user): "Connected as \(user.displayName)"
        case .unavailable(let error): error.userMessage
        }
    }
}

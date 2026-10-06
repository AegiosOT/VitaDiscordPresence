import Foundation

/// One line of JSON the menu-bar app writes to `vitapresence-discord`.
///
/// `setActivity` always includes `activity`, and a missing activity is JSON `null`. `quit` asks the helper to
/// close the socket without that null activity and then exit: Discord drops the presence when the process ends.
public struct DiscordHelperCommand: Codable, Sendable, Equatable {
    public var cmd: String
    public var clientID: String?
    public var socket: String?
    public var activity: DiscordActivity?

    public init(cmd: String, clientID: String? = nil, socket: String? = nil, activity: DiscordActivity? = nil) {
        self.cmd = cmd
        self.clientID = clientID
        self.socket = socket
        self.activity = activity
    }

    public static func connect(clientID: String, socket: String?, activity: DiscordActivity? = nil) -> DiscordHelperCommand {
        DiscordHelperCommand(cmd: "connect", clientID: clientID, socket: socket, activity: activity)
    }

    public static func setActivity(_ activity: DiscordActivity?) -> DiscordHelperCommand {
        DiscordHelperCommand(cmd: "setActivity", activity: activity)
    }

    public static func quit() -> DiscordHelperCommand {
        DiscordHelperCommand(cmd: "quit")
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cmd, forKey: .cmd)
        try container.encodeIfPresent(clientID, forKey: .clientID)
        try container.encodeIfPresent(socket, forKey: .socket)
        if cmd == "setActivity" {
            if let activity {
                try container.encode(activity, forKey: .activity)
            } else {
                try container.encodeNil(forKey: .activity)
            }
        } else if cmd == "connect", let activity {
            // Sent with the handshake so Discord never sits on the application's name.
            try container.encode(activity, forKey: .activity)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cmd = try container.decode(String.self, forKey: .cmd)
        clientID = try container.decodeIfPresent(String.self, forKey: .clientID)
        socket = try container.decodeIfPresent(String.self, forKey: .socket)
        if cmd == "setActivity" || cmd == "connect" {
            if container.contains(.activity), try container.decodeNil(forKey: .activity) {
                activity = nil
            } else {
                activity = try container.decodeIfPresent(DiscordActivity.self, forKey: .activity)
            }
        } else {
            activity = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case cmd, clientID, socket, activity
    }
}

/// One line of JSON the helper writes back.
public struct DiscordHelperEvent: Codable, Sendable, Equatable {
    public var evt: String
    public var user: DiscordUser?
    public var error: DiscordIPCError?

    public init(evt: String, user: DiscordUser? = nil, error: DiscordIPCError? = nil) {
        self.evt = evt
        self.user = user
        self.error = error
    }

    public static func ready(_ user: DiscordUser) -> DiscordHelperEvent {
        DiscordHelperEvent(evt: "ready", user: user)
    }

    public static func activity() -> DiscordHelperEvent {
        DiscordHelperEvent(evt: "activity")
    }

    public static func failure(_ error: DiscordIPCError) -> DiscordHelperEvent {
        DiscordHelperEvent(evt: "error", error: error)
    }
}

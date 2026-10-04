/// The Discord account reported in the READY dispatch.
public struct DiscordUser: Sendable, Equatable, Codable {
    public var id: String
    public var username: String
    /// Display name. `nil` when the user hasn't set one.
    public var globalName: String?

    public init(id: String, username: String, globalName: String? = nil) {
        self.id = id
        self.username = username
        self.globalName = globalName
    }

    /// The name people see: `globalName`, or `username` when there is no display name.
    public var displayName: String {
        if let globalName, !globalName.isEmpty { return globalName }
        return username
    }

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case globalName = "global_name"
    }
}

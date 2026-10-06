import DiscordIPC
import Foundation
import VitaKit

/// Everything the user configures. Shared by the app (persisted in UserDefaults) and the CLI (from
/// arguments). The defaults work out of the box: the Vita is found automatically and the built-in Discord
/// application is used.
public struct PresenceSettings: Sendable, Equatable, Codable {
    /// The Vita's IPv4 address or MAC address, as typed. Empty (or `auto`) means find it automatically.
    public var address: String
    /// A custom Discord application (client) ID. Empty means the built-in `defaultClientID`.
    public var clientID: String
    /// Optional custom second line ("state") under the game name.
    public var stateText: String
    /// Optional Discord asset key or https image URL that replaces the automatic game artwork.
    public var largeImageKey: String
    /// Seconds between polls when the Vita is answering. Clamped to `pollIntervalRange` when used.
    public var pollInterval: Double
    /// Show "elapsed" time since the current game (or LiveArea visit) started.
    public var showElapsedTime: Bool
    /// When `false`, the presence is cleared while the Vita is in the LiveArea instead of showing
    /// "In the LiveArea".
    public var showLiveArea: Bool
    /// Look up the running game's artwork (store art or box art) and show it as the large image.
    public var showGameArtwork: Bool

    public static let defaultPollInterval: Double = 10
    public static let pollIntervalRange: ClosedRange<Double> = 3...300
    /// The shared "PlayStation Vita" Discord application every user gets unless they set their own.
    public static let defaultClientID = "1556140114374037715"

    public init(
        address: String = "",
        clientID: String = "",
        stateText: String = "",
        largeImageKey: String = "",
        pollInterval: Double = PresenceSettings.defaultPollInterval,
        showElapsedTime: Bool = true,
        showLiveArea: Bool = true,
        showGameArtwork: Bool = true
    ) {
        self.address = address
        self.clientID = clientID
        self.stateText = stateText
        self.largeImageKey = largeImageKey
        self.pollInterval = pollInterval
        self.showElapsedTime = showElapsedTime
        self.showLiveArea = showLiveArea
        self.showGameArtwork = showGameArtwork
    }

    /// The same names the synthesized `encode(to:)` writes.
    private enum CodingKeys: String, CodingKey {
        case address, clientID, stateText, largeImageKey, pollInterval, showElapsedTime, showLiveArea,
             showGameArtwork
    }

    /// Tolerant decoding: any missing or mistyped key falls back to its default, so settings saved by older
    /// or newer versions still load.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PresenceSettings()
        func decode<Value: Decodable>(_ key: CodingKeys, or fallback: Value) -> Value {
            (try? container.decodeIfPresent(Value.self, forKey: key)) ?? fallback
        }
        self.init(
            address: decode(.address, or: defaults.address),
            clientID: decode(.clientID, or: defaults.clientID),
            stateText: decode(.stateText, or: defaults.stateText),
            largeImageKey: decode(.largeImageKey, or: defaults.largeImageKey),
            pollInterval: decode(.pollInterval, or: defaults.pollInterval),
            showElapsedTime: decode(.showElapsedTime, or: defaults.showElapsedTime),
            showLiveArea: decode(.showLiveArea, or: defaults.showLiveArea),
            showGameArtwork: decode(.showGameArtwork, or: defaults.showGameArtwork)
        )
    }

    /// `pollInterval` clamped to `pollIntervalRange` (non-finite values become the default).
    public var effectivePollInterval: Duration {
        guard pollInterval.isFinite else { return .seconds(Self.defaultPollInterval) }
        let range = Self.pollIntervalRange
        return .seconds(min(max(pollInterval, range.lowerBound), range.upperBound))
    }

    /// The parsed address (`.automatic` when empty), or `nil` when it isn't a valid IPv4 or MAC address.
    public var vitaAddress: VitaAddress? {
        VitaAddress(address)
    }

    /// `clientID` with surrounding whitespace removed.
    public var trimmedClientID: String {
        clientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The Discord application to connect with: the custom ID when one is set, otherwise `defaultClientID`.
    public var effectiveClientID: String {
        let custom = trimmedClientID
        return custom.isEmpty ? Self.defaultClientID : custom
    }

    /// `true` when a custom Discord application ID is set.
    public var usesCustomClientID: Bool {
        !trimmedClientID.isEmpty
    }

    /// Why `largeImageKey` won't be shown, or `nil` when it is blank or Discord would accept it.
    /// An asset name with the built-in application is included: Discord has no such asset to show.
    public var largeImageWarning: String? {
        let image = largeImageKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !image.isEmpty else { return nil }
        let lowercased = image.lowercased()
        if lowercased.hasPrefix("http:") || lowercased.hasPrefix("https:") {
            if DiscordActivity.acceptableImage(image) == nil {
                return "Use an https URL of at most 256 characters, with no spaces"
            }
            return nil
        }
        if !usesCustomClientID {
            return "An asset name only works with your own Discord application"
        }
        return nil
    }

    /// Problems that prevent connecting, in display order. Empty when the settings are usable, which includes
    /// the defaults. A custom client ID must be 16–25 ASCII digits after trimming.
    public var issues: [Issue] {
        var issues: [Issue] = []
        if vitaAddress == nil {
            issues.append(.invalidAddress)
        }
        if usesCustomClientID, !Self.isValidClientID(trimmedClientID) {
            issues.append(.invalidClientID)
        }
        return issues
    }

    public enum Issue: Sendable, Equatable {
        case invalidAddress
        case invalidClientID

        /// User-facing text, such as "That isn't a valid IP or MAC address".
        public var message: String {
            switch self {
            case .invalidAddress: "That isn't a valid IP or MAC address"
            case .invalidClientID: "The application ID should be 16 to 25 digits"
            }
        }
    }

    /// Discord application IDs are snowflakes: 16–25 ASCII digits.
    private static func isValidClientID(_ clientID: String) -> Bool {
        let digits = UInt8(ascii: "0")...UInt8(ascii: "9")
        return (16...25).contains(clientID.utf8.count) && clientID.utf8.allSatisfy(digits.contains)
    }
}

extension String {
    /// `true` when the string is empty or only whitespace and newlines.
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

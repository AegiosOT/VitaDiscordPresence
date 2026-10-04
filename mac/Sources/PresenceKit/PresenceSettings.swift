import Foundation
import VitaKit

/// Everything the user configures. Shared by the app (persisted in UserDefaults) and the CLI (from
/// arguments).
public struct PresenceSettings: Sendable, Equatable, Codable {
    /// The Vita's IPv4 address or MAC address, as typed.
    public var address: String
    /// The Discord application (client) ID from the Developer Portal.
    public var clientID: String
    /// Optional custom second line ("state") under the game name.
    public var stateText: String
    /// Optional Discord asset key or https image URL for the large image.
    public var largeImageKey: String
    /// Seconds between polls when the Vita is answering. Clamped to `pollIntervalRange` when used.
    public var pollInterval: Double
    /// Show "elapsed" time since the current game (or LiveArea visit) started.
    public var showElapsedTime: Bool
    /// When `false`, the presence is cleared while the Vita is in the LiveArea instead of showing
    /// "In the LiveArea".
    public var showLiveArea: Bool

    public static let defaultPollInterval: Double = 10
    public static let pollIntervalRange: ClosedRange<Double> = 3...300

    public init(
        address: String = "",
        clientID: String = "",
        stateText: String = "",
        largeImageKey: String = "",
        pollInterval: Double = PresenceSettings.defaultPollInterval,
        showElapsedTime: Bool = true,
        showLiveArea: Bool = true
    ) {
        self.address = address
        self.clientID = clientID
        self.stateText = stateText
        self.largeImageKey = largeImageKey
        self.pollInterval = pollInterval
        self.showElapsedTime = showElapsedTime
        self.showLiveArea = showLiveArea
    }

    /// The same names the synthesized `encode(to:)` writes.
    private enum CodingKeys: String, CodingKey {
        case address, clientID, stateText, largeImageKey, pollInterval, showElapsedTime, showLiveArea
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
            showLiveArea: decode(.showLiveArea, or: defaults.showLiveArea)
        )
    }

    /// `pollInterval` clamped to `pollIntervalRange` (non-finite values become the default).
    public var effectivePollInterval: Duration {
        guard pollInterval.isFinite else { return .seconds(Self.defaultPollInterval) }
        let range = Self.pollIntervalRange
        return .seconds(min(max(pollInterval, range.lowerBound), range.upperBound))
    }

    /// The parsed address, or `nil` when it isn't a valid IPv4 or MAC address.
    public var vitaAddress: VitaAddress? {
        VitaAddress(address)
    }

    /// `clientID` with surrounding whitespace removed.
    public var trimmedClientID: String {
        clientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Problems that prevent connecting, in display order. Empty when the settings are usable.
    /// The client ID must be 16–25 ASCII digits after trimming.
    public var issues: [Issue] {
        var issues: [Issue] = []
        if address.isBlank {
            issues.append(.missingAddress)
        } else if vitaAddress == nil {
            issues.append(.invalidAddress)
        }
        let clientID = trimmedClientID
        if clientID.isEmpty {
            issues.append(.missingClientID)
        } else if !Self.isValidClientID(clientID) {
            issues.append(.invalidClientID)
        }
        return issues
    }

    public enum Issue: Sendable, Equatable {
        case missingAddress
        case invalidAddress
        case missingClientID
        case invalidClientID

        /// User-facing text, such as "Enter your Vita's IP or MAC address".
        public var message: String {
            switch self {
            case .missingAddress: "Enter your Vita's IP or MAC address"
            case .invalidAddress: "That isn't a valid IP or MAC address"
            case .missingClientID: "Enter your Discord application ID"
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

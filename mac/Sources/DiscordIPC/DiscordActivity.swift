import Foundation

/// The `activity` object of a Discord `SET_ACTIVITY` command.
///
/// Encodes with Discord's snake_case keys and omits `nil` fields, because Discord rejects the whole update
/// when any field breaks its rules. Use `sanitized()` before sending.
public struct DiscordActivity: Sendable, Equatable, Codable {
    /// First line under the app name, such as the game title. 2–128 UTF-16 code units.
    public var details: String?
    /// Second line, such as a custom status. 2–128 UTF-16 code units.
    public var state: String?
    public var timestamps: Timestamps?
    /// Images. Only send this when there is an image; text without an image is never shown.
    public var assets: Assets?

    public init(details: String? = nil, state: String? = nil, timestamps: Timestamps? = nil, assets: Assets? = nil) {
        self.details = details
        self.state = state
        self.timestamps = timestamps
        self.assets = assets
    }

    public struct Timestamps: Sendable, Equatable, Codable {
        /// Unix time in **milliseconds** when the activity started. Discord then shows "elapsed".
        public var start: Int64?

        public init(start: Int64?) {
            self.start = start
        }
    }

    public struct Assets: Sendable, Equatable, Codable {
        /// An uploaded asset key (lowercase) or an https image URL. 1–300 characters.
        public var largeImage: String?
        /// Hover text for the large image. 2–128 UTF-16 code units.
        public var largeText: String?

        public init(largeImage: String?, largeText: String? = nil) {
            self.largeImage = largeImage
            self.largeText = largeText
        }

        enum CodingKeys: String, CodingKey {
            case largeImage = "large_image"
            case largeText = "large_text"
        }
    }

    /// Longest `assets.largeImage` Discord accepts, in UTF-16 code units.
    static let maximumImageLength = 300

    /// A copy that satisfies Discord's validation:
    /// - `details`, `state` and `assets.largeText` go through `DiscordText.clamp` (empty becomes `nil`)
    /// - `assets.largeImage` is trimmed, `nil` when empty, and cut to 300 characters (UTF-16 code units,
    ///   as Discord counts them, on a grapheme-cluster boundary)
    /// - `assets` is dropped entirely when there is no large image
    /// - `timestamps` is dropped when `start` is `nil` or not positive
    public func sanitized() -> DiscordActivity {
        var result = DiscordActivity(details: DiscordText.clamp(details), state: DiscordText.clamp(state))
        if let start = timestamps?.start, start > 0 {
            result.timestamps = Timestamps(start: start)
        }
        if let image = assets?.largeImage?.trimmingCharacters(in: .whitespacesAndNewlines), !image.isEmpty {
            result.assets = Assets(
                largeImage: String(DiscordText.prefix(image, maxUnits: Self.maximumImageLength)),
                largeText: DiscordText.clamp(assets?.largeText)
            )
        }
        return result
    }
}

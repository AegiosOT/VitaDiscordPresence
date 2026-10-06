import Foundation

/// The `activity` object of a Discord `SET_ACTIVITY` command.
///
/// Encodes with Discord's snake_case keys and omits `nil` fields, because Discord rejects the whole update
/// when any field breaks its rules. Use `sanitized()` before sending.
public struct DiscordActivity: Sendable, Equatable, Codable {
    /// Activity type; `0` is "Playing". Discord accepts 0, 2, 3 and 5.
    public var type: Int?
    /// Replaces the application's name as the bold title, e.g. "Playing **Persona 4 Golden**". 1–128 UTF-16
    /// code units. When `nil`, Discord shows the application's name.
    public var name: String?
    /// First line under the title. 2–128 UTF-16 code units.
    public var details: String?
    /// Second line, such as a custom status. 2–128 UTF-16 code units.
    public var state: String?
    public var timestamps: Timestamps?
    /// Images. When there is no image at all, Discord shows the application's icon.
    public var assets: Assets?

    public init(
        type: Int? = nil,
        name: String? = nil,
        details: String? = nil,
        state: String? = nil,
        timestamps: Timestamps? = nil,
        assets: Assets? = nil
    ) {
        self.type = type
        self.name = name
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
        /// An uploaded asset key (lowercase) or an https image URL.
        public var largeImage: String?
        /// Hover text for the large image. 2–128 UTF-16 code units.
        public var largeText: String?
        /// A small badge over the large image: an asset key or an https image URL.
        public var smallImage: String?
        /// Hover text for the small image. 2–128 UTF-16 code units.
        public var smallText: String?

        public init(largeImage: String?, largeText: String? = nil, smallImage: String? = nil, smallText: String? = nil) {
            self.largeImage = largeImage
            self.largeText = largeText
            self.smallImage = smallImage
            self.smallText = smallText
        }

        enum CodingKeys: String, CodingKey {
            case largeImage = "large_image"
            case largeText = "large_text"
            case smallImage = "small_image"
            case smallText = "small_text"
        }
    }

    /// Longest asset key Discord accepts, in UTF-16 code units.
    static let maximumImageLength = 300
    /// Longest external image URL Discord can sign (its external-assets endpoint takes at most 256 characters,
    /// and a longer one can make the whole update fail).
    static let maximumImageURLLength = 256

    /// A copy that satisfies Discord's validation:
    /// - `name` goes through `DiscordText.clamp` with a minimum of 1; `details`, `state` and the image texts
    ///   with the default minimum of 2 (empty becomes `nil`)
    /// - an image is an asset key (trimmed, cut to 300 UTF-16 code units) or an `https://` URL of at most 256
    ///   characters without whitespace; anything else (other schemes, longer URLs) is dropped
    /// - an image's text is dropped with its image, and `assets` is dropped when no image is left
    /// - `timestamps` is dropped when `start` is `nil` or not positive
    public func sanitized() -> DiscordActivity {
        var result = DiscordActivity(
            type: type,
            name: DiscordText.clamp(name, minUnits: 1),
            details: DiscordText.clamp(details),
            state: DiscordText.clamp(state)
        )
        if let start = timestamps?.start, start > 0 {
            result.timestamps = Timestamps(start: start)
        }
        let largeImage = Self.acceptableImage(assets?.largeImage)
        let smallImage = Self.acceptableImage(assets?.smallImage)
        if largeImage != nil || smallImage != nil {
            result.assets = Assets(
                largeImage: largeImage,
                largeText: largeImage == nil ? nil : DiscordText.clamp(assets?.largeText),
                smallImage: smallImage,
                smallText: smallImage == nil ? nil : DiscordText.clamp(assets?.smallText)
            )
        }
        return result
    }

    /// An asset key or an acceptable https URL, or `nil` when `image` would be dropped (http, too long, or
    /// an https URL with whitespace).
    public static func acceptableImage(_ image: String?) -> String? {
        guard let image = image?.trimmingCharacters(in: .whitespacesAndNewlines), !image.isEmpty else { return nil }
        let lowercased = image.lowercased()
        guard lowercased.hasPrefix("http:") || lowercased.hasPrefix("https:") else {
            return String(DiscordText.prefix(image, maxUnits: maximumImageLength))
        }
        guard lowercased.hasPrefix("https://"), image.utf16.count <= maximumImageURLLength,
              !image.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) })
        else { return nil }
        return image
    }
}

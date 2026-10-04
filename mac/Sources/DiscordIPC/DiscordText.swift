import Foundation

/// Discord validates activity strings by length in **UTF-16 code units** (2–128 for details, state and
/// image text), and rejects the entire update when one field breaks the rule.
public enum DiscordText {
    /// U+200B ZERO WIDTH SPACE, used to pad one-character strings up to the 2-unit minimum.
    public static let padding: Character = "\u{200B}"
    /// U+2026 HORIZONTAL ELLIPSIS, appended to strings that were cut.
    static let ellipsis: Character = "\u{2026}"

    /// Makes `text` acceptable to Discord:
    /// 1. trims whitespace and newlines, and returns `nil` when nothing is left or `text` is `nil`;
    /// 2. when longer than `maxUnits`, cuts on a grapheme-cluster boundary so the result plus a trailing
    ///    `…` fits in `maxUnits` (never splitting a surrogate pair or a combining sequence);
    /// 3. when shorter than `minUnits`, appends `padding` until the minimum is reached.
    public static func clamp(_ text: String?, minUnits: Int = 2, maxUnits: Int = 128) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        var result = trimmed
        if result.utf16.count > maxUnits {
            result = String(prefix(trimmed, maxUnits: maxUnits - ellipsis.utf16.count))
            result.append(ellipsis)
        }
        while result.utf16.count < minUnits {
            result.append(padding)
        }
        return result
    }

    /// The longest prefix of `text` that ends on a grapheme-cluster boundary and is at most `maxUnits`
    /// UTF-16 code units long.
    static func prefix(_ text: String, maxUnits: Int) -> Substring {
        var end = text.startIndex
        var units = 0
        while end < text.endIndex {
            let next = text.index(after: end)
            let clusterUnits = text.utf16.distance(from: end, to: next)
            guard units + clusterUnits <= maxUnits else { break }
            units += clusterUnits
            end = next
        }
        return text[..<end]
    }
}

import Foundation

/// Lookup results by key: found artwork for 30 days, "nothing found" for 3 days.
struct ArtworkCache: Sendable {
    static let hitLifetime: TimeInterval = 30 * 24 * 60 * 60
    static let missLifetime: TimeInterval = 3 * 24 * 60 * 60

    enum Result: Equatable, Sendable {
        case found(URL)
        case nothing

        var url: URL? {
            if case .found(let url) = self { return url }
            return nil
        }
    }

    struct Entry: Equatable, Sendable {
        /// The artwork, or `nil` when nothing was found.
        var url: String?
        var checkedAt: Date
        /// A hit found only after an earlier source failed in a way a retry might fix. Kept for `missLifetime`,
        /// not 30 days, so the preferred source is asked again.
        var provisional: Bool

        init(url: String?, checkedAt: Date, provisional: Bool = false) {
            self.url = url
            self.checkedAt = checkedAt
            self.provisional = provisional
        }
    }

    private(set) var entries: [String: Entry] = [:]

    /// The result remembered for `key`, or `nil` when there is none or it has expired. An entry checked "in the
    /// future" (the clock went back) counts as expired.
    func result(for key: String, at date: Date) -> Result? {
        guard let entry = entries[key], Self.isFresh(entry, at: date) else { return nil }
        guard let text = entry.url else { return .nothing }
        return URL(string: text).map(Result.found)
    }

    mutating func record(_ result: Result, for key: String, at date: Date, provisional: Bool = false) {
        entries[key] = Entry(url: result.url?.absoluteString, checkedAt: date, provisional: provisional && result.url != nil)
    }

    /// Keeps the newer entry for each key. Used when the app and the CLI write the same cache file.
    mutating func merge(_ other: ArtworkCache) {
        for (key, entry) in other.entries where entries[key].map({ $0.checkedAt < entry.checkedAt }) ?? true {
            entries[key] = entry
        }
    }

    mutating func removeExpired(at date: Date) {
        entries = entries.filter { Self.isFresh($0.value, at: date) }
    }

    /// The cache in `file`. A missing, unreadable or corrupt file gives an empty cache, and entries whose URL
    /// breaks the artwork URL rules are dropped.
    static func load(from file: URL) -> ArtworkCache {
        guard let stored = JSONFile.read(Stored.self, from: file), stored.version == Stored.currentVersion else {
            return ArtworkCache()
        }
        var cache = ArtworkCache()
        cache.entries = stored.entries.filter { _, entry in
            entry.url.map { URL(string: $0).map(ArtworkURL.isAcceptable) ?? false } ?? true
        }
        return cache
    }

    /// Writes the cache to `file` atomically, creating its directory. Failures are ignored.
    func save(to file: URL) {
        JSONFile.write(Stored(version: Stored.currentVersion, entries: entries), to: file)
    }

    private static func isFresh(_ entry: Entry, at date: Date) -> Bool {
        let age = date.timeIntervalSince(entry.checkedAt)
        let lifetime = entry.url == nil || entry.provisional ? missLifetime : hitLifetime
        return age >= 0 && age < lifetime
    }

    private struct Stored: Codable {
        static let currentVersion = 1
        var version: Int
        var entries: [String: Entry]
    }
}

extension ArtworkCache.Entry: Codable {
    private enum CodingKeys: String, CodingKey {
        case url, checkedAt, provisional
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        checkedAt = try container.decode(Date.self, forKey: .checkedAt)
        provisional = try container.decodeIfPresent(Bool.self, forKey: .provisional) ?? false
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encode(checkedAt, forKey: .checkedAt)
        if provisional {
            try container.encode(true, forKey: .provisional)
        }
    }
}

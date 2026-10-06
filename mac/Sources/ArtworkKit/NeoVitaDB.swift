import Foundation

/// The NeoVitaDB homebrew catalog: title IDs with square 128×128 PNG icons.
enum NeoVitaDB {
    static let catalogURL = URL(string: "https://robin994.github.io/NeoVitaDB-Catalog/vita.json")!
    static let iconsURL = "https://robin994.github.io/NeoVitaDB-Catalog/icons/"
    /// Adrenaline's own title ID. Its icon also stands for Adrenaline's PSP menu (`XMB`).
    static let adrenalineTitleID = "PSPEMUCFW"
    /// How long a fetched catalog is used before fetching it again (the published file is about 1.6 MB).
    static let refreshInterval: TimeInterval = 24 * 60 * 60
    /// How long to wait after a failed fetch before trying again.
    static let retryDelay: TimeInterval = 5 * 60

    struct Entry: Codable, Hashable, Sendable {
        var titleID: String
        var name: String
        /// File name under `icons/`, such as `0047-adrenaline.png`.
        var icon: String
    }

    /// A fetched catalog. Several entries may share a title ID (some homebrew reuse placeholder IDs).
    struct Catalog: Sendable {
        let fetchedAt: Date
        let entries: [Entry]
        private let byTitleID: [String: [Entry]]

        init(fetchedAt: Date, entries: [Entry]) {
            self.fetchedAt = fetchedAt
            self.entries = entries
            byTitleID = Dictionary(grouping: entries, by: \.titleID)
        }

        func entries(for titleID: String) -> [Entry] {
            byTitleID[titleID] ?? []
        }

        /// `true` until `refreshInterval` after it was fetched (and never for a fetch time in the future).
        func isFresh(at date: Date) -> Bool {
            let age = date.timeIntervalSince(fetchedAt)
            return age >= 0 && age < refreshInterval
        }
    }

    /// Fetches and parses the catalog.
    static func fetchCatalog(using http: any HTTPClient, at date: Date) async -> Fetch {
        do {
            let response = try await http.send(HTTPRequest(.get, catalogURL, timeout: .seconds(30)))
            guard response.status == 200 else { return response.isDefinitive ? .missing : .failed }
            return .fetched(Catalog(fetchedAt: date, entries: try parseCatalog(response.body)))
        } catch {
            return .failed
        }
    }

    enum Fetch: Sendable {
        case fetched(Catalog)
        /// The server answered that there is no catalog (a 4xx status).
        case missing
        /// Offline, a timeout, a server error, or a body that isn't a catalog: worth trying again later.
        case failed
    }

    /// Parses the published `vita.json`, an array of objects with `titleid`, `name` and `icon` strings, and
    /// skips entries without a title ID or icon. Throws when `data` isn't such an array.
    static func parseCatalog(_ data: Data) throws -> [Entry] {
        try JSONDecoder().decode([PublishedEntry].self, from: data).compactMap { published in
            let titleID = published.titleid?.trimmingCharacters(in: .whitespaces).uppercased() ?? ""
            guard !titleID.isEmpty, let icon = published.icon, !icon.isEmpty else { return nil }
            return Entry(titleID: titleID, name: published.name ?? "", icon: icon)
        }
    }

    /// The URL of `entry`'s icon, or `nil` when its file name isn't plain (it must start with a letter or digit
    /// and contain only letters, digits, `.`, `-` and `_`).
    static func iconURL(for entry: Entry) -> URL? {
        let scalars = entry.icon.unicodeScalars
        guard let first = scalars.first, first.isASCIIAlphanumeric,
              scalars.allSatisfy({ $0.isASCIIAlphanumeric || $0 == "." || $0 == "-" || $0 == "_" })
        else { return nil }
        return URL(string: iconsURL + entry.icon)
    }

    /// How closely a catalog entry's name has to match the running title's name.
    enum NameRule: Sendable, Hashable {
        /// Every entry for the title ID, those whose name matches first.
        case preferred
        /// A title ID's only entry as it is; among several, only those whose name matches.
        case requiredIfShared
        /// Only entries whose name matches.
        case required
    }

    /// The entries for `titleID` worth trying, best first: names that are equal, then names that contain one
    /// another, then (only for `.preferred`) the rest.
    static func candidates(in catalog: Catalog, titleID: String, name: String, rule: NameRule) -> [Entry] {
        let entries = catalog.entries(for: titleID)
        let equal = entries.filter { nameMatch($0.name, name) == .equal }
        let similar = entries.filter { nameMatch($0.name, name) == .contained }
        switch rule {
        case .preferred:
            return equal + similar + entries.filter { nameMatch($0.name, name) == nil }
        case .requiredIfShared where entries.count == 1:
            return entries
        case .requiredIfShared, .required:
            return equal + similar
        }
    }

    enum NameMatch {
        case equal
        /// One contains the other, and the shorter has at least 4 letters or digits.
        case contained
    }

    /// Compares two names ignoring case, accents, character width, punctuation and spaces.
    static func nameMatch(_ lhs: String, _ rhs: String) -> NameMatch? {
        let left = comparable(lhs)
        let right = comparable(rhs)
        guard !left.isEmpty, !right.isEmpty else { return nil }
        if left == right { return .equal }
        let (shorter, longer) = left.count < right.count ? (left, right) : (right, left)
        return shorter.count >= 4 && longer.contains(shorter) ? .contained : nil
    }

    /// The letters and digits of `name`, folded: "Vita Pong™" and "ＶＩＴＡＰＯＮＧ" both become "vitapong".
    /// Trademark signs go first, since compatibility mapping would turn "™" into "TM".
    private static func comparable(_ name: String) -> String {
        let folded = name.replacingOccurrences(of: "[™℠®©]", with: "", options: .regularExpression)
            .precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }))
    }

    /// One object of the published catalog; fields that are missing or of another type read as `nil`.
    private struct PublishedEntry: Decodable {
        var titleid: String?
        var name: String?
        var icon: String?

        private enum CodingKeys: String, CodingKey {
            case titleid, name, icon
        }

        init(from decoder: any Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            titleid = try? container?.decode(String.self, forKey: .titleid)
            name = try? container?.decode(String.self, forKey: .name)
            icon = try? container?.decode(String.self, forKey: .icon)
        }
    }

    /// The catalog as kept on disk: only the fields lookups use.
    struct StoredCatalog: Codable {
        var version = 1
        var fetchedAt: Date
        var entries: [Entry]

        init(_ catalog: Catalog) {
            fetchedAt = catalog.fetchedAt
            entries = catalog.entries
        }

        /// The catalog in `file`, or `nil` when it is missing, unreadable or of another version.
        static func load(from file: URL) -> Catalog? {
            guard let stored = JSONFile.read(StoredCatalog.self, from: file), stored.version == 1 else { return nil }
            return Catalog(fetchedAt: stored.fetchedAt, entries: stored.entries)
        }
    }
}

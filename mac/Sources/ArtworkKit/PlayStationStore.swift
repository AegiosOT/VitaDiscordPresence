import Foundation

/// The PlayStation Store's "chihiro" API: square official art by content ID, and a name search that leads from
/// a title ID to a content ID.
enum PlayStationStore {
    static let api = "https://store.playstation.com/store/api/chihiro/00_09_000"

    /// A store country and language as chihiro paths spell them (`US/en`). A product only answers in the
    /// storefront of its region; anywhere else it is a 404.
    struct Storefront: Hashable, Sendable {
        var country: String
        var language: String

        static let unitedStates = Storefront(country: "US", language: "en")
        static let unitedKingdom = Storefront(country: "GB", language: "en")
        static let japan = Storefront(country: "JP", language: "ja")
        static let singapore = Storefront(country: "SG", language: "en")
        static let korea = Storefront(country: "KR", language: "ko")

        init(country: String, language: String) {
            self.country = country
            self.language = language
        }

        /// The storefront of a content ID, from its first letter: `U`→US/en, `E`→GB/en, `J`→JP/ja, `H`→SG/en,
        /// `K`→KR/ko, anything else US/en.
        init(contentID: String) {
            switch contentID.uppercased().first {
            case "E": self = .unitedKingdom
            case "J": self = .japan
            case "H": self = .singapore
            case "K": self = .korea
            default: self = .unitedStates
            }
        }

        /// The storefront of a Vita or PSP title ID: PCSA/PCSE→US, PCSB/PCSF→GB, PCSC/PCSG→JP, PCSD/PCSH→SG;
        /// PSP serials by their region letter, the third (`ULUS`, `UCUS`, `NPUH`→US; `ULES`, `NPEZ`→GB;
        /// `ULJM`, `UCJS`, `NPJH`→JP; `ULAS`, `NPHH`→SG; `ULKS`, `NPKx`→KR). Anything else is US/en.
        init(titleID: String) {
            let id = Array(titleID.uppercased())
            let region: Character?
            if id.starts(with: "PCS"), id.count > 3 {
                switch id[3] {
                case "A", "E": region = "U"
                case "B", "F": region = "E"
                case "C", "G": region = "J"
                case "D", "H": region = "H"
                default: region = nil
                }
            } else {
                region = id.count > 2 ? id[2] : nil
            }
            switch region {
            case "E": self = .unitedKingdom
            case "J": self = .japan
            case "A", "H": self = .singapore
            case "K": self = .korea
            default: self = .unitedStates
            }
        }
    }

    /// `true` for the 36-character content ID shape `XXYYYY-TTTTNNNNN_NN-LLLLLLLLLLLLLLLL` (letters and digits).
    static func isContentID(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count == 36 else { return false }
        return scalars.indices.allSatisfy { index in
            switch index {
            case 6, 19: scalars[index] == "-"
            case 16: scalars[index] == "_"
            default: scalars[index].isASCIIAlphanumeric
            }
        }
    }

    /// The store image of `contentID`, in the URL form proven to render in Discord (no query string, 133
    /// characters for a US product): 200 `image/jpeg`, 1024² or smaller.
    static func imageURL(contentID: String, in storefront: Storefront) -> URL? {
        guard isContentID(contentID) else { return nil }
        return URL(
            string: "\(api)/container/\(storefront.country)/\(storefront.language)/19/\(contentID)/1534563384000/image"
        )
    }

    /// The search ("tumbler") URL for `query`. Its JSON lists products under `links`.
    static func searchURL(for query: String, in storefront: Storefront) -> URL? {
        // A slash becomes %2F in the path, and the store edge answers 404 for that. Treat it as a space.
        let safe = query.replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path = safe.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        let base = "\(api)/tumbler/\(storefront.country)/\(storefront.language)/999/\(path)"
        return URL(string: base + "?suggested_size=10&mode=game")
    }

    /// Queries to search for a title, most specific first and at most three: the cleaned name, then its part
    /// before the first ":" and its part before the first " - ", longer one first.
    static func searchQueries(for name: String) -> [String] {
        let full = cleanedName(name.replacingOccurrences(of: "/", with: " "))
        let shorter = [
            prefix(of: full, before: [":", "："]),
            prefix(of: full, before: [" - ", " – ", " — "]),
            name.split(separator: "/", maxSplits: 1).first.map { cleanedName(String($0)) } ?? nil,
        ]
        .compactMap { $0 }
        .sorted { $0.count > $1.count }
        var queries: [String] = []
        for query in [full] + shorter where !query.isEmpty && !queries.contains(query) {
            queries.append(query)
        }
        return Array(queries.prefix(3))
    }

    /// `name` without ™ ® ©, without a trailing "PlayStation®Vita Edition" (with or without a colon before it),
    /// and with whitespace collapsed.
    static func cleanedName(_ name: String) -> String {
        name.replacingOccurrences(of: "[™®©]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(
                of: "\\s*:?\\s*PlayStation\\s*Vita\\s+Edition\\s*$",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(of: "\\s+(?=[:：])", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// The content IDs in a search response that belong to `titleID`, in the response's order: only IDs
    /// containing `-<TITLEID>_00-`, never a merely similar name, and no add-ons (DLC art isn't the game's).
    /// Throws when `body` isn't a search response.
    static func products(in body: Data, matching titleID: String) throws -> [String] {
        let marker = "-\(titleID.uppercased())_00-"
        var contentIDs: [String] = []
        for link in try JSONDecoder().decode(SearchResponse.self, from: body).links ?? [] {
            guard let id = link.id?.uppercased(), isContentID(id), id.contains(marker),
                  link.topCategory != "add_on", !contentIDs.contains(id)
            else { continue }
            contentIDs.append(id)
        }
        return contentIDs
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// `text` up to the earliest of `separators`, trimmed, or `nil` when none occurs.
    private static func prefix(of text: String, before separators: [String]) -> String? {
        separators.compactMap { text.range(of: $0)?.lowerBound }.min().map {
            text[..<$0].trimmingCharacters(in: .whitespaces)
        }
    }

    private struct SearchResponse: Decodable {
        var links: [Link]?
    }

    /// A search result. Fields that are missing or of another type read as `nil`, so one odd product doesn't
    /// spoil the rest.
    private struct Link: Decodable {
        var id: String?
        var topCategory: String?

        private enum CodingKeys: String, CodingKey {
            case id
            case topCategory = "top_category"
        }

        init(from decoder: any Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            id = try? container?.decode(String.self, forKey: .id)
            topCategory = try? container?.decode(String.self, forKey: .topCategory)
        }
    }
}

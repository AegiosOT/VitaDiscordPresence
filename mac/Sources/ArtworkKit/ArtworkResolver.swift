import Foundation
import VitaKit

/// Finds a public https image for the game the Vita is running, for Discord's large image.
public protocol ArtworkResolving: Sendable {
    /// The artwork URL for `title`, or `nil` when there is none (LiveArea, system apps, unknown titles,
    /// offline). Never throws; results, misses included, are cached (a miss only when every source answered).
    func artwork(for title: VitaTitle) async -> URL?
}

/// Resolves artwork from several public sources, preferring square official store art.
///
/// Order, stopping at the first image that answers HTTP 200 with an `image/*` type to a HEAD probe:
/// 1. LiveArea and system apps (`NPXS…`): none. The LiveArea icon is added later, without a lookup.
/// 2. Adrenaline's menu (`XMB`): Adrenaline's icon from the NeoVitaDB catalog (`PSPEMUCFW`).
/// 3. `title.contentID` (newer plugins): the PlayStation Store image for it, in the storefront its first
///    letter implies (`U`→US/en, `E`→GB/en, `J`→JP/ja, `H`→SG/en, `K`→KR/ko, else US/en).
/// 4. A PlayStation Store search for `title.name` in the storefront the title ID implies, accepting only a
///    product whose ID contains `-<TITLEID>_00-` (never a merely similar name), then its store image.
/// 5. Homebrew: the NeoVitaDB catalog icon for the title ID (catalog fetched at most once a day).
/// 6. HexFlow-Covers box art by title ID: `PSVita/`, `PSP/` or `PS1/` by `title.kind`.
///
/// Per kind: Vita and PSP games use 3, 4, then 5 when the names match, then 6. PS1 games use 3, then 5 when
/// the names match, then 6 (the store sells PS1 games under PSN IDs, so a search can't match the disc serial).
/// Homebrew (`.other`) uses 3, 5 and then `PSVita/` covers. A retail-looking title ID that NeoVitaDB lists
/// under the same name gets that icon before HexFlow: an exact ID plus a matching name is stronger than an
/// ID-only cover. Searches try the cleaned name, then its part
/// before ":" or " - ", at most 3 requests, and stop at the first one that finds the title ID.
///
/// Store image URL form (the one proven to render in Discord):
/// `https://store.playstation.com/store/api/chihiro/00_09_000/container/{CC}/{lang}/19/{CONTENT_ID}/1534563384000/image`
///
/// Results are cached per title ID + content ID: hits for 30 days, misses for 3 days, in memory and in
/// `cacheFile` (JSON) when given. Concurrent requests for the same title share one lookup. Every URL handed out
/// is https, at most 256 characters, and has no query string.
///
/// A lookup is cached as a miss only when every source answered for good. When one couldn't be asked
/// (offline, a timeout, a 5xx or 429, a body that doesn't parse), the miss isn't cached and the next call tries
/// again. The catalog is kept next to `cacheFile` (`neovitadb.json`); when it can't be refreshed, the copy on
/// hand is used, and without one that source is skipped. A failed refresh is retried after 5 minutes at the
/// earliest.
public actor ArtworkResolver: ArtworkResolving {
    private let http: any HTTPClient
    private let cacheFile: URL?
    private let now: @Sendable () -> Date

    /// Remembered results, read from `cacheFile` on first use.
    private var cache: ArtworkCache?
    /// Lookups in progress by cache key. A caller asking for a key that is being looked up waits for that
    /// lookup instead of starting another.
    private var lookups: [String: Task<URL?, Never>] = [:]
    /// How many callers joined a lookup that was already running. Tests wait on this instead of sleeping.
    var joinedLookups = 0
    /// The NeoVitaDB catalog on hand; older than a day only when the latest refresh failed.
    private var catalog: NeoVitaDB.Catalog?
    private var hasReadCatalogFile = false
    /// The catalog refresh in progress, shared by concurrent lookups.
    private var catalogRefresh: Task<CatalogState, Never>?
    /// The latest failed refresh: what it gave, and when.
    private var catalogFailure: (state: CatalogState, date: Date)?

    public init(
        http: any HTTPClient = URLSessionHTTPClient(),
        cacheFile: URL? = ArtworkResolver.defaultCacheFile,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.http = http
        self.cacheFile = cacheFile
        self.now = now
    }

    /// `~/Library/Caches/io.github.aegiosot.VitaPresence/artwork.json`.
    public static var defaultCacheFile: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("io.github.aegiosot.VitaPresence", isDirectory: true)
            .appendingPathComponent("artwork.json")
    }

    public func artwork(for title: VitaTitle) async -> URL? {
        guard let query = Query(title) else { return nil }
        if let result = loadedCache().result(for: query.key, at: now()) { return result.url }
        if let lookup = lookups[query.key] {
            joinedLookups += 1
            return await lookup.value
        }
        let lookup = Task { finish(query, with: await answer(for: query)) }
        lookups[query.key] = lookup
        return await lookup.value
    }

    // MARK: Lookup

    /// Asks each source in turn and stops at the first image found.
    private func answer(for query: Query) async -> Answer {
        var probed: Set<URL> = []
        var sawUnknown = false
        var answer = Answer.nothing
        for source in query.sources {
            switch await ask(source, about: query, probed: &probed) {
            case .found(let url), .provisional(let url):
                // A later source's picture must not be remembered for 30 days when an earlier one might
                // still answer on a retry.
                return sawUnknown ? .provisional(url) : .found(url)
            case .unknown:
                sawUnknown = true
                answer = .unknown
            case .nothing:
                break
            }
        }
        return answer
    }

    private func ask(_ source: Source, about query: Query, probed: inout Set<URL>) async -> Answer {
        switch source {
        case .storeImage(let contentID):
            let storefront = PlayStationStore.Storefront(contentID: contentID)
            return await probe([PlayStationStore.imageURL(contentID: contentID, in: storefront)], &probed)
        case .storeSearch:
            return await searchStore(for: query, probed: &probed)
        case .catalogIcon(let titleID, let name, let rule):
            return await catalogIcon(titleID: titleID, name: name, rule: rule, probed: &probed)
        case .hexFlowCover(let folder):
            if await shouldSkipSharedHexFlow(query) { return .nothing }
            return await probe([HexFlowCovers.coverURL(titleID: query.titleID, in: folder)], &probed)
        }
    }

    /// Searches the store by name, query by query, and probes the images of this title ID's products that the
    /// first query to list any of them finds.
    private func searchStore(for query: Query, probed: inout Set<URL>) async -> Answer {
        let storefront = PlayStationStore.Storefront(titleID: query.titleID)
        var answer = Answer.nothing
        for text in PlayStationStore.searchQueries(for: query.name) {
            guard let url = PlayStationStore.searchURL(for: text, in: storefront) else { continue }
            let response: HTTPResponse
            do {
                response = try await http.send(HTTPRequest(.get, url))
            } catch {
                // Offline or timing out: the other queries would fail the same way.
                return .unknown
            }
            guard response.status == 200 else {
                if !response.isDefinitive { answer = .unknown }
                continue
            }
            guard let contentIDs = try? PlayStationStore.products(in: response.body, matching: query.titleID) else {
                answer = .unknown
                continue
            }
            guard !contentIDs.isEmpty else { continue }
            let images = contentIDs.map { PlayStationStore.imageURL(contentID: $0, in: storefront) }
            switch await probe(images, &probed) {
            case .found(let image): return .found(image)
            case .provisional(let image): return .provisional(image)
            case .unknown: return .unknown
            case .nothing: return answer
            }
        }
        return answer
    }

    private func catalogIcon(
        titleID: String,
        name: String,
        rule: NeoVitaDB.NameRule,
        probed: inout Set<URL>
    ) async -> Answer {
        switch await currentCatalog() {
        case .available(let catalog):
            let entries = NeoVitaDB.candidates(in: catalog, titleID: titleID, name: name, rule: rule)
            return await probe(entries.map(NeoVitaDB.iconURL(for:)), &probed)
        case .missing:
            return .nothing
        case .unavailable:
            return .unknown
        }
    }

    /// HEADs each URL in turn until one answers 200 with an `image/*` type. URLs that break the artwork URL
    /// rules, and URLs already probed during this lookup, are skipped.
    private func probe(_ urls: [URL?], _ probed: inout Set<URL>) async -> Answer {
        var answer = Answer.nothing
        for case let url? in urls {
            guard ArtworkURL.isAcceptable(url), probed.insert(url).inserted else { continue }
            do {
                let response = try await http.send(HTTPRequest(.head, url))
                if response.status == 200, response.mediaType?.hasPrefix("image/") == true { return .found(url) }
                if !response.isDefinitive { answer = .unknown }
            } catch {
                answer = .unknown
            }
        }
        return answer
    }

    /// Caches a lookup's result unless it is `.unknown`, and ends the lookup.
    private func finish(_ query: Query, with answer: Answer) -> URL? {
        lookups[query.key] = nil
        switch answer {
        case .found(let url):
            record(.found(url), for: query.key)
            return url
        case .provisional(let url):
            record(.found(url), for: query.key, provisional: true)
            return url
        case .nothing:
            record(.nothing, for: query.key)
            return nil
        case .unknown:
            return nil
        }
    }

    // MARK: Cache

    private func loadedCache() -> ArtworkCache {
        if let cache { return cache }
        let loaded = cacheFile.map(ArtworkCache.load(from:)) ?? ArtworkCache()
        cache = loaded
        return loaded
    }

    private func record(_ result: ArtworkCache.Result, for key: String, provisional: Bool = false) {
        let date = now()
        var updated = loadedCache()
        if let cacheFile {
            updated.merge(ArtworkCache.load(from: cacheFile))
        }
        updated.record(result, for: key, at: date, provisional: provisional)
        updated.removeExpired(at: date)
        cache = updated
        if let cacheFile { updated.save(to: cacheFile) }
    }

    /// Placeholder title IDs shared by several catalog entries have no single cover. Skip HexFlow's ID-only
    /// picture when none of those entries matches the running title.
    private func shouldSkipSharedHexFlow(_ query: Query) async -> Bool {
        guard query.kind == .other else { return false }
        guard case .available(let catalog) = await currentCatalog() else { return false }
        guard catalog.entries(for: query.titleID).count >= 2 else { return false }
        return NeoVitaDB.candidates(
            in: catalog,
            titleID: query.titleID,
            name: query.name,
            rule: .required
        ).isEmpty
    }

    // MARK: NeoVitaDB catalog

    private enum CatalogState: Sendable {
        case available(NeoVitaDB.Catalog)
        /// There is no catalog: the server said so and no copy is on hand.
        case missing
        /// The catalog couldn't be fetched and no copy is on hand.
        case unavailable
    }

    /// `neovitadb.json` next to `cacheFile`.
    private var catalogFile: URL? {
        cacheFile?.deletingLastPathComponent().appendingPathComponent("neovitadb.json")
    }

    /// The catalog on hand while it is less than a day old, otherwise a fresh one. Concurrent callers share
    /// one refresh, and after a failed one the next waits `NeoVitaDB.retryDelay`.
    private func currentCatalog() async -> CatalogState {
        if !hasReadCatalogFile {
            hasReadCatalogFile = true
            if catalog == nil, let catalogFile {
                catalog = NeoVitaDB.StoredCatalog.load(from: catalogFile)
            }
        }
        let date = now()
        if let catalog, catalog.isFresh(at: date) { return .available(catalog) }
        if let catalogFailure, (0..<NeoVitaDB.retryDelay).contains(date.timeIntervalSince(catalogFailure.date)) {
            return catalog.map(CatalogState.available) ?? catalogFailure.state
        }
        if let refresh = catalogRefresh { return await refresh.value }
        let refresh = Task { await refreshCatalog() }
        catalogRefresh = refresh
        return await refresh.value
    }

    private func refreshCatalog() async -> CatalogState {
        let fetch = await NeoVitaDB.fetchCatalog(using: http, at: now())
        catalogRefresh = nil
        let failed: CatalogState
        switch fetch {
        case .fetched(let fresh):
            let replacedGoodCopy = fresh.entries.isEmpty
            if replacedGoodCopy {
                failed = .unavailable
            } else {
                catalog = fresh
                catalogFailure = nil
                if let catalogFile { JSONFile.write(NeoVitaDB.StoredCatalog(fresh), to: catalogFile) }
                return .available(fresh)
            }
        case .missing:
            failed = .missing
        case .failed:
            failed = .unavailable
        }
        catalogFailure = (failed, now())
        return catalog.map(CatalogState.available) ?? failed
    }
}

extension ArtworkResolver {
    /// What a source, or a whole lookup, found.
    enum Answer: Equatable, Sendable {
        case found(URL)
        /// Nothing, and every request got a lasting answer.
        case nothing
        /// A picture, found after an earlier source failed in a way a retry might fix. Remembered briefly.
        case provisional(URL)
        /// Nothing, but a request failed in a way a retry might fix.
        case unknown
    }

    /// A title as the resolver looks it up.
    struct Query: Sendable {
        /// Trimmed and uppercased.
        var titleID: String
        var name: String
        /// Uppercased, and only when it has the content ID shape.
        var contentID: String?
        var kind: VitaTitle.Kind

        /// `nil` for titles that never have artwork: the LiveArea, system apps and empty title IDs.
        init?(_ title: VitaTitle) {
            var normalized = title
            normalized.titleID = title.titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            normalized.name = title.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let kind = normalized.kind
            guard !normalized.titleID.isEmpty, kind != .liveArea, kind != .systemApp else { return nil }
            titleID = normalized.titleID
            name = normalized.name
            contentID = title.contentID
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
                .flatMap { PlayStationStore.isContentID($0) ? $0 : nil }
            self.kind = kind
        }

        /// The cache key: the title ID, plus the content ID when there is one. Homebrew also includes the
        /// name, because several apps share a title ID and only a matching name is the right icon.
        var key: String {
            let base = contentID.map { "\(titleID)|\($0)" } ?? titleID
            guard kind == .other else { return base }
            let normalized = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .split { $0.isWhitespace }
                .joined(separator: " ")
            return normalized.isEmpty ? base : "\(base)|\(normalized)"
        }

        /// The sources to ask, in order.
        var sources: [Source] {
            let storeImage = contentID.map { [Source.storeImage($0)] } ?? []
            // A search needs a name; the title ID itself finds nothing.
            let storeSearch = name.isEmpty || name.uppercased() == titleID ? [] : [Source.storeSearch]
            let namedIcon = name.isEmpty ? [] : [Source.catalogIcon(titleID: titleID, name: name, rule: .required)]
            switch kind {
            case .liveArea, .systemApp:
                return []
            case .adrenalineMenu:
                return [.catalogIcon(titleID: NeoVitaDB.adrenalineTitleID, name: "Adrenaline", rule: .preferred)]
            case .vitaGame:
                return storeImage + storeSearch + namedIcon + [.hexFlowCover(.vita)]
            case .pspGame:
                return storeImage + storeSearch + namedIcon + [.hexFlowCover(.psp)]
            case .ps1Game:
                return storeImage + namedIcon + [.hexFlowCover(.ps1)]
            case .other:
                return storeImage + [
                    .catalogIcon(titleID: titleID, name: name, rule: .requiredIfShared),
                    .hexFlowCover(.vita),
                ]
            }
        }
    }

    /// Where artwork can come from.
    enum Source: Equatable, Sendable {
        /// The store image of this content ID.
        case storeImage(String)
        /// A store search by name for products of the title ID.
        case storeSearch
        /// The NeoVitaDB icon for a title ID.
        case catalogIcon(titleID: String, name: String, rule: NeoVitaDB.NameRule)
        /// HexFlow box art for the title ID.
        case hexFlowCover(HexFlowCovers.Folder)
    }
}

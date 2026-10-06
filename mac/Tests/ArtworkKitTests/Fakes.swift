import Foundation
import os
import VitaKit
@testable import ArtworkKit

// MARK: - URLs

let storeAPI = "https://store.playstation.com/store/api/chihiro/00_09_000"
let catalogURL = "https://robin994.github.io/NeoVitaDB-Catalog/vita.json"

/// The store image of `contentID` in the `country`/`language` storefront.
func storeImage(_ contentID: String, _ country: String = "US", _ language: String = "en") -> String {
    "\(storeAPI)/container/\(country)/\(language)/19/\(contentID)/1534563384000/image"
}

/// The store search for `encodedQuery` (already percent-encoded) in the `country`/`language` storefront.
func storeSearch(_ encodedQuery: String, _ country: String = "US", _ language: String = "en") -> String {
    "\(storeAPI)/tumbler/\(country)/\(language)/999/\(encodedQuery)?suggested_size=10&mode=game"
}

func hexFlowCover(_ folder: String, _ titleID: String) -> String {
    "https://raw.githubusercontent.com/Andiweli/HexFlow-Covers/main/Covers/\(folder)/\(titleID).png"
}

func catalogIcon(_ file: String) -> String {
    "https://robin994.github.io/NeoVitaDB-Catalog/icons/\(file)"
}

// MARK: - Bodies

/// A store search response listing `products` (content ID, name, `top_category`).
func searchResponse(_ products: [(id: String, name: String, category: String)] = []) -> String {
    let links = products.map { product in
        """
        {"id":"\(product.id)","name":"\(product.name)","top_category":"\(product.category)",\
        "playable_platform":["PS Vita"],"images":[{"type":1,"url":"https://example.com/1.png"}]}
        """
    }
    return #"{"size":\#(products.count),"links":[\#(links.joined(separator: ","))]}"#
}

/// A NeoVitaDB `vita.json` with `entries` (title ID, name, icon file).
func catalogBody(_ entries: [(titleID: String, name: String, icon: String)]) -> String {
    let objects = entries.map { entry in
        #"{"name":"\#(entry.name)","icon":"\#(entry.icon)","titleid":"\#(entry.titleID)","id":"1","type":"1"}"#
    }
    return "[\(objects.joined(separator: ","))]"
}

let standardCatalog = catalogBody([
    ("VITASHELL", "VitaShell", "0021-vitashell.png"),
    ("PSPEMUCFW", "Adrenaline", "0047-adrenaline.png"),
    ("RETROVITA", "RetroArch", "1534-retroarch.png"),
    ("PCSF00092", "History Deleter", "1520-history-deleter.png"),
])

// MARK: - Titles

func makeTitle(_ titleID: String, _ name: String, contentID: String? = nil) -> VitaTitle {
    VitaTitle(index: 2, titleID: titleID, name: name, contentID: contentID)
}

let personaUS = makeTitle("PCSE00120", "Persona 4 Golden")
let personaUSStoreID = "UP0005-PCSE00120_00-PERSONA4GOLDEN01"
let vitaShell = makeTitle("VITASHELL", "VitaShell")
let metalGear = makeTitle("SLUS00594", "Metal Gear Solid")
let adrenalineMenu = makeTitle("XMB", "XMB")

// MARK: - Fake HTTP

/// A scripted `HTTPClient`: it answers by method and URL, records every request, and answers anything
/// unscripted with 404.
final class FakeHTTPClient: HTTPClient {
    indirect enum Reply: Sendable {
        case response(HTTPResponse)
        case failure(URLError.Code)
        /// Waits until the gate opens, then gives the reply.
        case held(Gate, Reply)

        static let image = Reply.response(HTTPResponse(status: 200, headers: ["content-type": "image/png"]))
        static let offline = Reply.failure(.notConnectedToInternet)

        static func status(_ status: Int, headers: [String: String] = [:]) -> Reply {
            .response(HTTPResponse(status: status, headers: headers))
        }

        static func json(_ body: String) -> Reply {
            .response(HTTPResponse(
                status: 200,
                headers: ["content-type": "application/json;charset=UTF-8"],
                body: Data(body.utf8)
            ))
        }
    }

    private struct State {
        var replies: [String: Reply] = [:]
        var requests: [HTTPRequest] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Answers `method` requests for `url` with `reply` from now on.
    func on(_ method: HTTPRequest.Method, _ url: String, _ reply: Reply) {
        state.withLock { $0.replies[Self.key(method, url)] = reply }
    }

    /// Every request so far, in order.
    var requests: [HTTPRequest] {
        state.withLock { $0.requests }
    }

    /// Every request so far as "METHOD url", in order.
    var log: [String] {
        requests.map { Self.key($0.method, $0.url.absoluteString) }
    }

    func count(_ method: HTTPRequest.Method, _ url: String) -> Int {
        log.filter { $0 == Self.key(method, url) }.count
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let reply = state.withLock { state in
            state.requests.append(request)
            return state.replies[Self.key(request.method, request.url.absoluteString)]
        }
        return try await perform(reply ?? .status(404))
    }

    private func perform(_ reply: Reply) async throws -> HTTPResponse {
        switch reply {
        case .response(let response):
            return response
        case .failure(let code):
            throw URLError(code)
        case .held(let gate, let next):
            await gate.wait()
            return try await perform(next)
        }
    }

    private static func key(_ method: HTTPRequest.Method, _ url: String) -> String {
        "\(method.rawValue) \(url)"
    }
}

/// Holds callers of `wait()` until `open()`.
final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let isOpen = state.withLock { state in
                if !state.isOpen { state.waiters.append(continuation) }
                return state.isOpen
            }
            if isOpen { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }
}

// MARK: - Clock and files

/// A settable clock for cache lifetimes.
final class TestClock: Sendable {
    private let date: OSAllocatedUnfairLock<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
        date = OSAllocatedUnfairLock(initialState: start)
    }

    var now: Date {
        date.withLock { $0 }
    }

    func advance(days: Double = 0, hours: Double = 0, minutes: Double = 0, seconds: Double = 0) {
        date.withLock { $0 += days * 86_400 + hours * 3_600 + minutes * 60 + seconds }
    }
}

/// A resolver on `http` with no cache file unless one is given, on `clock`.
func makeResolver(_ http: FakeHTTPClient, cacheFile: URL? = nil, clock: TestClock = TestClock()) -> ArtworkResolver {
    ArtworkResolver(http: http, cacheFile: cacheFile, now: { clock.now })
}

/// A new empty directory under the temporary directory. Remove it when done.
func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ArtworkKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Polls `condition` every few milliseconds until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while true {
        if await condition() { return true }
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

import Foundation
import Testing
@testable import ArtworkKit

/// `URLSessionHTTPClient` against a loopback `LoopbackHTTPServer`.
struct URLSessionHTTPClientTests {
    let client = URLSessionHTTPClient()

    @Test func returnsStatusLowercasedHeadersAndBody() async throws {
        let server = try await LoopbackHTTPServer { _ in
            .init(
                status: 404,
                headers: ["Content-Type": "text/plain", "X-Custom-Header": "Value"],
                body: Data("nope".utf8)
            )
        }
        defer { server.stop() }
        let response = try await client.send(HTTPRequest(.get, server.url("/missing")))
        #expect(response.status == 404)
        #expect(response.headers["x-custom-header"] == "Value")
        #expect(response.mediaType == "text/plain")
        #expect(response.body == Data("nope".utf8))
        #expect(response.headers.keys.allSatisfy { $0 == $0.lowercased() })
    }

    @Test(arguments: [200, 204, 403, 410, 429, 500, 503])
    func anyStatusIsAResponse(_ status: Int) async throws {
        let server = try await LoopbackHTTPServer { _ in .init(status: status) }
        defer { server.stop() }
        #expect(try await client.send(HTTPRequest(.get, server.url("/"))).status == status)
    }

    @Test func sendsTheMethodPathAndUserAgent() async throws {
        let server = try await LoopbackHTTPServer { _ in .init(status: 200, headers: ["Content-Type": "image/png"]) }
        defer { server.stop() }
        _ = try await client.send(HTTPRequest(.get, server.url("/a/b.json")))
        _ = try await client.send(HTTPRequest(.head, server.url("/c.png")))
        let requests = server.requests
        #expect(requests.map(\.method) == ["GET", "HEAD"])
        #expect(requests.map(\.path) == ["/a/b.json", "/c.png"])
        #expect(requests.allSatisfy {
            $0.headers["user-agent"] == "VitaPresence/2.0 (+https://github.com/AegiosOT/VitaDiscordPresence)"
        })
    }

    @Test func headHasNoBody() async throws {
        let server = try await LoopbackHTTPServer { _ in
            .init(
                status: 200,
                headers: ["Content-Type": "image/jpeg;charset=UTF-8"],
                body: Data(repeating: 7, count: 64)
            )
        }
        defer { server.stop() }
        let response = try await client.send(HTTPRequest(.head, server.url("/image")))
        #expect(response.status == 200)
        #expect(response.mediaType == "image/jpeg")
        #expect(response.body.isEmpty)
    }

    @Test func headReturnsARedirectAsItIs() async throws {
        let server = try await LoopbackHTTPServer { request in
            request.path == "/moved"
                ? .init(status: 302, headers: ["Location": "/image"])
                : .init(status: 200, headers: ["Content-Type": "image/png"])
        }
        defer { server.stop() }
        let response = try await client.send(HTTPRequest(.head, server.url("/moved")))
        #expect(response.status == 302)
        #expect(response.headers["location"] == "/image")
        #expect(server.requests.map(\.path) == ["/moved"])
    }

    @Test func getFollowsRedirects() async throws {
        let server = try await LoopbackHTTPServer { request in
            request.path == "/moved"
                ? .init(status: 301, headers: ["Location": "/catalog.json"])
                : .init(status: 200, headers: ["Content-Type": "application/json"], body: Data("[]".utf8))
        }
        defer { server.stop() }
        let response = try await client.send(HTTPRequest(.get, server.url("/moved")))
        #expect(response.status == 200)
        #expect(response.body == Data("[]".utf8))
        #expect(server.requests.map(\.path) == ["/moved", "/catalog.json"])
    }

    @Test func neverSendsCookies() async throws {
        let server = try await LoopbackHTTPServer { _ in
            .init(status: 200, headers: ["Set-Cookie": "bm_sz=abc123; Path=/; Max-Age=3600"])
        }
        defer { server.stop() }
        _ = try await client.send(HTTPRequest(.get, server.url("/first")))
        _ = try await client.send(HTTPRequest(.get, server.url("/second")))
        #expect(server.requests.count == 2)
        #expect(server.requests.allSatisfy { $0.headers["cookie"] == nil })
    }

    @Test func neverAnswersFromACache() async throws {
        let server = try await LoopbackHTTPServer { _ in
            .init(
                status: 200,
                headers: [
                    "Content-Type": "application/json",
                    "Cache-Control": "public, max-age=86400",
                    "ETag": "\"v1\"",
                    "Last-Modified": "Sun, 04 Oct 2026 03:14:33 GMT",
                ],
                body: Data("{}".utf8)
            )
        }
        defer { server.stop() }
        for _ in 0..<2 {
            #expect(try await client.send(HTTPRequest(.get, server.url("/catalog.json"))).body == Data("{}".utf8))
        }
        #expect(server.requests.count == 2)
        #expect(server.requests.allSatisfy {
            $0.headers["if-none-match"] == nil && $0.headers["if-modified-since"] == nil
        })
    }

    @Test func timesOutWithoutAnAnswer() async throws {
        let server = try await LoopbackHTTPServer { _ in nil }
        defer { server.stop() }
        let start = ContinuousClock.now
        await #expect(throws: URLError.self) {
            _ = try await client.send(HTTPRequest(.get, server.url("/slow"), timeout: .milliseconds(300)))
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func cancellingTheTaskCancelsTheRequest() async throws {
        let server = try await LoopbackHTTPServer { _ in nil }
        defer { server.stop() }
        let request = Task { try await client.send(HTTPRequest(.get, server.url("/hang"), timeout: .seconds(30))) }
        #expect(await eventually { server.requests.count == 1 })
        let start = ContinuousClock.now
        request.cancel()
        await #expect(throws: CancellationError.self) { _ = try await request.value }
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func anAlreadyCancelledTaskSendsNothing() async throws {
        let server = try await LoopbackHTTPServer { _ in .init(status: 200) }
        defer { server.stop() }
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.send(HTTPRequest(.get, server.url("/never")))
        }
        await #expect(throws: CancellationError.self) { _ = try await request.value }
        #expect(server.requests.isEmpty)
    }

    @Test func refusedConnectionThrows() async throws {
        let server = try await LoopbackHTTPServer { _ in .init(status: 200) }
        let url = server.url("/gone")
        server.stop()
        await #expect(throws: URLError.self) { _ = try await client.send(HTTPRequest(.get, url, timeout: .seconds(5))) }
    }

    @Test(arguments: ["file:///etc/hosts", "data:text/plain,hello", "ftp://example.com/file"])
    func onlyHTTPURLsAreSent(_ url: String) async throws {
        await #expect(throws: URLError(.unsupportedURL)) {
            _ = try await client.send(HTTPRequest(.get, try #require(URL(string: url))))
        }
    }
}

import Foundation
import Testing
@testable import DiscordIPC

@Suite struct DiscordIPCPathTests {
    @Test func ordersDirectoriesLikeDiscord() {
        let paths = DiscordIPCPath.candidates(
            environment: [
                "XDG_RUNTIME_DIR": "/run/user/501",
                "TMPDIR": "/var/folders/ab/T/",
                "TMP": "/var/tmp/a",
                "TEMP": "/var/tmp/b",
                "HOME": "/Users/someone",
            ],
            darwinUserTempDir: "/var/folders/cd/T/"
        )
        #expect(directories(of: paths) == [
            "/run/user/501", "/var/folders/ab/T", "/var/tmp/a", "/var/tmp/b", "/var/folders/cd/T", "/tmp",
        ])
        #expect(paths.count == 60)
        #expect(Array(paths.prefix(10)) == (0...9).map { "/run/user/501/discord-ipc-\($0)" })
    }

    @Test func deduplicatesAfterRemovingTrailingSlashes() {
        let paths = DiscordIPCPath.candidates(
            environment: ["TMPDIR": "/var/folders/ab/T/", "TMP": "/var/folders/ab/T", "TEMP": "/tmp//"],
            darwinUserTempDir: "/var/folders/ab/T///"
        )
        #expect(directories(of: paths) == ["/var/folders/ab/T", "/tmp"])
        #expect(paths.count == 20)
        #expect(paths[0] == "/var/folders/ab/T/discord-ipc-0")
    }

    @Test func skipsEmptyValues() {
        let paths = DiscordIPCPath.candidates(
            environment: ["XDG_RUNTIME_DIR": "", "TMPDIR": "", "TMP": "", "TEMP": ""],
            darwinUserTempDir: ""
        )
        #expect(paths == (0...9).map { "/tmp/discord-ipc-\($0)" })
    }

    @Test func fallsBackToTmp() {
        let paths = DiscordIPCPath.candidates(environment: [:], darwinUserTempDir: nil)
        #expect(paths == (0...9).map { "/tmp/discord-ipc-\($0)" })
    }

    @Test func includesTheDarwinUserTempDirBeforeTmp() {
        let paths = DiscordIPCPath.candidates(environment: [:], darwinUserTempDir: "/var/folders/cd/T/")
        #expect(directories(of: paths) == ["/var/folders/cd/T", "/tmp"])
    }

    @Test func rootDirectoryGetsASingleSlash() {
        let paths = DiscordIPCPath.candidates(environment: ["TMPDIR": "/"], darwinUserTempDir: nil)
        #expect(paths.first == "/discord-ipc-0")
    }

    @Test func leavesOutPathsThatDontFitSunPath() {
        // "/discord-ipc-N" adds 14 bytes: an 89-byte directory gives 103-byte paths, a 90-byte one 104.
        let fits = "/" + String(repeating: "a", count: 88)
        let tooLong = "/" + String(repeating: "b", count: 89)
        let paths = DiscordIPCPath.candidates(environment: ["TMPDIR": fits, "TMP": tooLong], darwinUserTempDir: nil)
        #expect(directories(of: paths) == [fits, "/tmp"])
        #expect(paths.first?.utf8.count == 103)
        #expect(paths.allSatisfy { $0.utf8.count < 104 })
    }

    @Test func measuresLengthInBytes() {
        // 46 characters but 91 bytes, so each path is 105 bytes long.
        let directory = "/" + String(repeating: "\u{E9}", count: 45)
        let paths = DiscordIPCPath.candidates(environment: ["TMPDIR": directory], darwinUserTempDir: nil)
        #expect(directories(of: paths) == ["/tmp"])
    }

    @Test func darwinUserTempDirIsAnExistingDirectory() throws {
        let directory = try #require(DiscordIPCPath.darwinUserTempDir())
        var isDirectory: ObjCBool = false
        #expect(directory.hasPrefix("/"))
        #expect(FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func defaultsUseTheRealEnvironment() throws {
        // Only computes strings; nothing connects. The environment may name any directory, /tmp included.
        let darwinDirectory = try #require(DiscordIPCPath.darwinUserTempDir())
        let trimmed = darwinDirectory.hasSuffix("/") ? String(darwinDirectory.dropLast()) : darwinDirectory
        let paths = DiscordIPCPath.candidates()
        #expect(paths == DiscordIPCPath.candidates(
            environment: ProcessInfo.processInfo.environment,
            darwinUserTempDir: darwinDirectory
        ))
        #expect(paths.contains(trimmed + "/discord-ipc-0"))
        #expect(paths.contains("/tmp/discord-ipc-9"))
        #expect(Set(paths).count == paths.count)
    }

    /// The directories contributing paths, in order.
    private func directories(of paths: [String]) -> [String] {
        let suffix = "/discord-ipc-0"
        return paths.filter { $0.hasSuffix(suffix) }.map { String($0.dropLast(suffix.count)) }
    }
}

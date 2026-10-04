// swift-tools-version: 6.0
import Foundation
import PackageDescription

// With only the Command Line Tools installed (no Xcode), Swift Testing's macro plugin lives in a
// subfolder SwiftPM doesn't search, so `swift test` fails with "plugin for module 'TestingMacros'
// not found". Point the compiler at it in that case; Xcode toolchains don't need this.
let cltTestingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let developerDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
    ?? (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")) ?? ""
let testSwiftSettings: [SwiftSetting] =
    developerDir.hasPrefix("/Library/Developer/CommandLineTools")
        && FileManager.default.fileExists(atPath: cltTestingPlugins)
    ? [.unsafeFlags(["-plugin-path", cltTestingPlugins])]
    : []

let package = Package(
    name: "VitaPresence",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VitaPresence", targets: ["VitaPresenceApp"]),
        .executable(name: "vitapresence-cli", targets: ["VitaPresenceCLI"]),
    ],
    targets: [
        // Vita protocol and LAN networking.
        .target(name: "VitaKit"),
        // Discord Rich Presence over the local IPC socket.
        .target(name: "DiscordIPC"),
        // Settings, presence rules and the poll loop shared by the app and the CLI.
        .target(name: "PresenceKit", dependencies: ["VitaKit", "DiscordIPC"]),
        .executableTarget(name: "VitaPresenceApp", dependencies: ["PresenceKit", "VitaKit", "DiscordIPC"]),
        .executableTarget(name: "VitaPresenceCLI", dependencies: ["PresenceKit", "VitaKit", "DiscordIPC"]),

        // Loopback mock servers (fake Vita plugin, fake Discord) shared by the test targets.
        .target(name: "TestSupport", dependencies: ["VitaKit", "DiscordIPC"], path: "Tests/TestSupport"),
        .testTarget(
            name: "VitaKitTests",
            dependencies: ["VitaKit", "TestSupport"],
            swiftSettings: testSwiftSettings
        ),
        .testTarget(
            name: "DiscordIPCTests",
            dependencies: ["DiscordIPC", "TestSupport"],
            swiftSettings: testSwiftSettings
        ),
        .testTarget(
            name: "PresenceKitTests",
            dependencies: ["PresenceKit", "VitaKit", "DiscordIPC", "TestSupport"],
            swiftSettings: testSwiftSettings
        ),
        // The app and CLI targets are tested through `@testable import` with fakes; the CLI tests also run the
        // built `vitapresence-cli` against the loopback mocks. No LAN traffic, no GUI.
        .testTarget(
            name: "VitaPresenceAppTests",
            dependencies: ["VitaPresenceApp", "PresenceKit", "VitaKit", "DiscordIPC"],
            swiftSettings: testSwiftSettings
        ),
        .testTarget(
            name: "VitaPresenceCLITests",
            dependencies: ["VitaPresenceCLI", "PresenceKit", "VitaKit", "DiscordIPC", "TestSupport"],
            swiftSettings: testSwiftSettings
        ),
    ]
)

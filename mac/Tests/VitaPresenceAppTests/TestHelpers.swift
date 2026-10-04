import Foundation
import os
import PresenceKit
@testable import VitaPresenceApp
import VitaKit

/// Settings that pass validation.
let validSettings = PresenceSettings(address: "192.168.1.20", clientID: "123456789012345678")

/// Records the calls `AppModel` makes, and publishes snapshots on request.
actor FakeController: PresenceControlling {
    enum Call: Equatable {
        case start(PresenceSettings)
        case update(PresenceSettings)
        case pollNow
        case stop
    }

    nonisolated let snapshots: AsyncStream<PresenceSnapshot>
    private nonisolated let continuation: AsyncStream<PresenceSnapshot>.Continuation
    private let stopDuration: Duration
    private(set) var calls: [Call] = []

    /// `stopDuration` makes `stop()` take that long, like a hung Discord connection.
    init(stopDuration: Duration = .zero) {
        (snapshots, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.stopDuration = stopDuration
    }

    func start(with settings: PresenceSettings) {
        calls.append(.start(settings))
    }

    func updateSettings(_ settings: PresenceSettings) {
        calls.append(.update(settings))
    }

    func pollNow() {
        calls.append(.pollNow)
    }

    func stop() async {
        calls.append(.stop)
        if stopDuration > .zero {
            try? await Task.sleep(for: stopDuration)
        }
    }

    nonisolated func publish(_ snapshot: PresenceSnapshot) {
        continuation.yield(snapshot)
    }
}

/// A login item that records requests instead of touching the system.
final class FakeLoginItem {
    var state: LaunchAtLogin.State
    /// The state a successful request to enable leads to.
    var stateAfterEnabling = LaunchAtLogin.State.enabled
    /// Thrown by the next requests when set.
    var error: (any Error)?
    private(set) var requests: [Bool] = []
    private(set) var settingsOpened = 0

    init(state: LaunchAtLogin.State = .disabled) {
        self.state = state
    }

    var launchAtLogin: LaunchAtLogin {
        LaunchAtLogin(
            state: { self.state },
            setEnabled: { enabled in
                self.requests.append(enabled)
                if let error = self.error { throw error }
                self.state = enabled ? self.stateAfterEnabling : .disabled
            },
            openSystemSettingsLoginItems: { self.settingsOpened += 1 }
        )
    }
}

/// `UserDefaults` stored in a fresh temporary directory, so tests never touch the user's preferences.
/// The directory is deleted when this is deallocated.
final class TemporaryDefaults {
    let defaults: UserDefaults
    private let directory: URL
    private let suite: String

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VitaPresenceAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // An absolute path as the suite name makes the preferences system use `<path>.plist`.
        suite = directory.appendingPathComponent("defaults").path
        guard let defaults = UserDefaults(suiteName: suite) else { throw TestError() }
        self.defaults = defaults
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

struct TestError: LocalizedError {
    var errorDescription: String? { "Something went wrong" }
}

/// A thread-safe counter.
final class Counter: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    var value: Int { count.withLock { $0 } }

    func increment() {
        count.withLock { $0 += 1 }
    }
}

/// Checks `condition` until it holds or `timeout` passes, and returns whether it held.
@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// Checks that `condition` holds for the whole of `duration`.
@MainActor
func stays(for duration: Duration, _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + duration
    while ContinuousClock.now < deadline {
        if !(await condition()) { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

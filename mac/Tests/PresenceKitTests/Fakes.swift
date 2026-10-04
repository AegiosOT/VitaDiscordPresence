import DiscordIPC
import Foundation
import VitaKit
@testable import PresenceKit

// MARK: - Fixtures

let persona = VitaTitle(index: 3, titleID: "PCSE00120", name: "Persona 4 Golden")
let gravityRush = VitaTitle(index: 5, titleID: "PCSA00011", name: "Gravity Rush")
let testUser = DiscordUser(id: "42", username: "tester", globalName: "Tester")
let validClientID = "123456789012345678"

extension PresenceSettings {
    /// Usable settings: an IPv4 address and a well-formed client ID.
    static let valid = PresenceSettings(address: "192.168.1.20", clientID: validClientID)
}

extension PresenceController.Configuration {
    /// Millisecond timings so controller tests finish quickly. Generous rate limit unless a test lowers it.
    static var fast: Self {
        var configuration = Self()
        configuration.pollIntervalOverride = .milliseconds(20)
        configuration.minimumRetryDelay = .milliseconds(20)
        configuration.maximumRetryDelay = .milliseconds(40)
        configuration.activityBurst = 50
        configuration.activityWindow = .seconds(1)
        configuration.settingsDebounce = .milliseconds(60)
        configuration.invalidClientIDRetry = .seconds(60)
        return configuration
    }
}

/// `date` in Unix milliseconds, as Discord timestamps carry it.
func milliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded())
}

// MARK: - Waiting

/// Polls `condition` every few milliseconds until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while true {
        if await condition() { return true }
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// Checks that `condition` holds for the whole of `duration`.
func stays(for duration: Duration, _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + duration
    while ContinuousClock.now < deadline {
        if !(await condition()) { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

// MARK: - Fake Vita

/// What one `FakeFetcher.fetchTitle` call does.
indirect enum FetchStep: Sendable {
    case title(VitaTitle)
    case failure(VitaConnectionError)
    /// Never returns; throws `CancellationError` once the calling task is cancelled.
    case hang
    /// Waits `delay` even if the calling task is cancelled meanwhile, then performs `step`. Models a fetcher
    /// that ignores cancellation, so its result arrives late.
    case late(FetchStep, after: Duration)
}

/// A scripted `VitaTitleFetching`: calls take the scripted steps in order and the last step repeats.
actor FakeFetcher: VitaTitleFetching {
    struct Call: Sendable {
        var host: String
        var at: ContinuousClock.Instant
    }

    private(set) var calls: [Call] = []
    /// Calls that ended because their task was cancelled.
    private(set) var cancelledCalls = 0
    private var script: [FetchStep]
    private var stepsByHost: [String: FetchStep] = [:]
    private var pauseAtCall: Int?
    private var isPaused = false

    init(_ steps: FetchStep...) {
        precondition(!steps.isEmpty)
        script = steps
    }

    init(steps: [FetchStep]) {
        precondition(!steps.isEmpty)
        script = steps
    }

    var callCount: Int { calls.count }

    /// Replaces the script.
    func setSteps(_ steps: FetchStep...) {
        precondition(!steps.isEmpty)
        script = steps
    }

    /// Makes every call to `host` take `step`, ignoring the script.
    func setStep(_ step: FetchStep, forHost host: String) {
        stepsByHost[host] = step
    }

    /// Holds call number `call` (1-based) until `resume()`, before it takes its step.
    func pause(atCall call: Int) {
        pauseAtCall = call
    }

    func resume() {
        isPaused = false
    }

    func fetchTitle(from host: String) async throws -> VitaTitle {
        calls.append(Call(host: host, at: .now))
        if calls.count == pauseAtCall { isPaused = true }
        do {
            while isPaused { try await Task.sleep(for: .milliseconds(2)) }
            return try await perform(stepsByHost[host] ?? nextScriptedStep())
        } catch is CancellationError {
            cancelledCalls += 1
            throw CancellationError()
        }
    }

    private func nextScriptedStep() -> FetchStep {
        script.count > 1 ? script.removeFirst() : script[0]
    }

    private func perform(_ step: FetchStep) async throws -> VitaTitle {
        switch step {
        case .title(let title):
            return title
        case .failure(let error):
            throw error
        case .hang:
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        case .late(let step, let delay):
            await Task.detached { try? await Task.sleep(for: delay) }.value
            return try await perform(step)
        }
    }
}

/// A `VitaHostResolving` that returns IPv4 addresses unchanged and maps every MAC to `macHost`.
actor FakeResolver: VitaHostResolving {
    private(set) var resolved: [VitaAddress] = []
    private(set) var invalidated: [VitaAddress] = []
    private let macHost: String
    private var error: VitaConnectionError?
    private var delay: Duration?

    init(macHost: String = "192.168.1.77") {
        self.macHost = macHost
    }

    /// Makes `resolve` fail with `error` (or succeed again with `nil`).
    func fail(with error: VitaConnectionError?) {
        self.error = error
    }

    /// Makes `resolve` take `delay`, like an ARP lookup or LAN scan.
    func setDelay(_ delay: Duration?) {
        self.delay = delay
    }

    func resolve(_ address: VitaAddress) async throws -> String {
        resolved.append(address)
        if let delay { try await Task.sleep(for: delay) }
        if let error { throw error }
        switch address {
        case .ipv4(let host): return host
        case .mac: return macHost
        }
    }

    func invalidate(_ address: VitaAddress) {
        invalidated.append(address)
    }
}

// MARK: - Fake Discord

/// A `DiscordPresenceSink` that records what it is asked to do.
actor FakeDiscord: DiscordPresenceSink {
    struct Update: Sendable {
        var activity: DiscordActivity?
        var at: ContinuousClock.Instant
    }

    /// Client IDs passed to `connect`, in order, with when each attempt started.
    private(set) var connectAttempts: [String] = []
    private(set) var connectTimes: [ContinuousClock.Instant] = []
    /// Every `setActivity` call made while connected, accepted or not.
    private(set) var attempts: [DiscordActivity?] = []
    /// The updates Discord accepted, in order.
    private(set) var accepted: [Update] = []
    /// `disconnect` calls. Clearing the activity is part of `disconnect()` (see `DiscordPresenceSink`), so
    /// the controller sends no clear of its own.
    private(set) var disconnects = 0
    private var connectedClientID: String?
    private var connectError: DiscordIPCError?
    private var connectHangs = false
    private var connectDuration: Duration?
    private var connectDelay: Duration?
    private var disconnectDuration: Duration?
    private var updatesHang = false
    private var rejection: (@Sendable (DiscordActivity?) -> DiscordIPCError?)?
    private let user: DiscordUser

    init(user: DiscordUser = testUser) {
        self.user = user
    }

    var acceptedActivities: [DiscordActivity?] { accepted.map(\.activity) }

    /// Makes `connect` throw `error` (or succeed again with `nil`).
    func failConnects(with error: DiscordIPCError?) {
        connectError = error
    }

    /// Makes `connect` wait until its task is cancelled.
    func setConnectHangs(_ hangs: Bool) {
        connectHangs = hangs
    }

    /// Makes `connect` take `duration`, unless its task is cancelled first, which throws `CancellationError`
    /// (like the real client's handshake).
    func setConnectDuration(_ duration: Duration?) {
        connectDuration = duration
    }

    /// Makes `connect` take `delay` even if its task is cancelled meanwhile, then succeed.
    func setConnectDelay(_ delay: Duration?) {
        connectDelay = delay
    }

    /// Makes `disconnect` take `duration`, like the real client waiting for the farewell clear and CLOSE when
    /// Discord doesn't answer.
    func setDisconnectDuration(_ duration: Duration?) {
        disconnectDuration = duration
    }

    /// Makes `setActivity` wait for a reply that never comes (until its task is cancelled).
    func setUpdatesHang(_ hangs: Bool) {
        updatesHang = hangs
    }

    /// Fails `setActivity` with the error `rule` returns. Errors other than `.rpcError` also close the
    /// connection, as the real client does.
    func reject(when rule: @escaping @Sendable (DiscordActivity?) -> DiscordIPCError?) {
        rejection = rule
    }

    /// Simulates Discord quitting: the connection closes without a CLOSE frame.
    func dropConnection() {
        connectedClientID = nil
    }

    func connect(clientID: String) async throws -> DiscordUser {
        connectAttempts.append(clientID)
        connectTimes.append(.now)
        if connectHangs { try await Task.sleep(for: .seconds(3600)) }
        if let connectDuration { try await Task.sleep(for: connectDuration) }
        if let connectDelay { await Task.detached { try? await Task.sleep(for: connectDelay) }.value }
        if let connectError { throw connectError }
        connectedClientID = clientID
        return user
    }

    func setActivity(_ activity: DiscordActivity?) async throws {
        guard connectedClientID != nil else { throw DiscordIPCError.notConnected }
        attempts.append(activity)
        if updatesHang { try await Task.sleep(for: .seconds(3600)) }
        if let error = rejection?(activity) {
            if case .rpcError = error {} else { connectedClientID = nil }
            throw error
        }
        accepted.append(Update(activity: activity, at: .now))
    }

    func disconnect() async {
        disconnects += 1
        connectedClientID = nil
        if let disconnectDuration { await Task.detached { try? await Task.sleep(for: disconnectDuration) }.value }
    }

    var isConnected: Bool { connectedClientID != nil }
}

// MARK: - Controller harness

struct Harness {
    let controller: PresenceController
    let fetcher: FakeFetcher
    let resolver: FakeResolver
    let discord: FakeDiscord
}

/// Runs `body` with a controller wired to fakes, and always stops the controller afterwards.
func withController(
    _ fetcher: FakeFetcher = FakeFetcher(.title(persona)),
    resolver: FakeResolver = FakeResolver(),
    discord: FakeDiscord = FakeDiscord(),
    configure: (inout PresenceController.Configuration) -> Void = { _ in },
    _ body: (Harness) async throws -> Void
) async throws {
    var configuration = PresenceController.Configuration.fast
    configure(&configuration)
    let controller = PresenceController(
        fetcher: fetcher,
        resolver: resolver,
        discord: discord,
        configuration: configuration
    )
    let harness = Harness(controller: controller, fetcher: fetcher, resolver: resolver, discord: discord)
    do {
        try await body(harness)
    } catch {
        await controller.stop()
        throw error
    }
    await controller.stop()
}

/// Collects what a `snapshots` consumer receives.
actor SnapshotCollector {
    private(set) var all: [PresenceSnapshot] = []

    func append(_ snapshot: PresenceSnapshot) {
        all.append(snapshot)
    }
}

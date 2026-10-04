import DiscordIPC
import Foundation
import VitaKit

/// The poll loop shared by the app and the CLI: polls the Vita, keeps Discord's activity in sync, and
/// publishes `PresenceSnapshot`s.
///
/// Behaviour:
/// - **Loop:** while running, each tick (1) connects to Discord if needed (after `.invalidClientID`, it
///   doesn't retry until the client ID changes or `invalidClientIDRetry` passes), (2) resolves the address,
///   (3) fetches the title, (4) computes the desired activity with `PresenceBuilder`, and (5) syncs it. Ticks
///   are `settings.effectivePollInterval` apart while the Vita answers. After failures they back off
///   exponentially from `minimumRetryDelay` to `maximumRetryDelay`, never faster than the poll interval
///   would be.
/// - **Sessions:** a session starts (sessionStart = now) when the first title arrives or
///   `VitaTitle.sessionKey` changes. If the Vita has been unreachable for `sessionResetAfter`, the session is
///   forgotten, so the next title starts a new one. "No previous title" is `nil`, never `""`, so the first
///   LiveArea packet starts a session.
/// - **Failures:** a single failed poll keeps the presence. After `clearAfterFailures` consecutive failures
///   the title becomes `nil` and the presence is cleared. A MAC address is invalidated in the resolver after
///   every failure.
/// - **Discord sync:** sends only when the desired activity differs from what was last accepted on the
///   current connection, and always after a (re)connect: each READY resets "last accepted" to unknown.
///   Rate-limited by a `TokenBucket` (`activityBurst` per `activityWindow`); while limited, only the newest
///   desired activity is sent once a token is free. A payload rejected with `.rpcError` isn't retried until
///   the desired activity changes. `.notConnected`, `.timedOut`, `.io` and `.closedByDiscord` mark Discord
///   as disconnected; the next tick reconnects.
/// - **Settings changes:** a different client ID disconnects Discord and reconnects immediately. A different
///   address resets the resolver, failure count, title and session, then polls immediately; a Discord
///   connection attempt in progress carries on. Presentation-only changes (state text, image, toggles)
///   re-sync from the last title after `settingsDebounce`. A different poll interval takes effect at once.
///   Results of a poll that started before an address change are discarded.
/// - **Responsiveness:** `pollNow()`, `updateSettings(_:)` and `stop()` interrupt the sleep between ticks
///   right away. `stop()` returns within about a second even mid-poll: it cancels the loop, disconnects
///   Discord (which clears the activity, best effort), and publishes `.idle`.
public actor PresenceController {
    public struct Configuration: Sendable {
        /// Consecutive failed polls before the presence is cleared.
        public var clearAfterFailures: Int = 2
        /// How long the Vita may be unreachable before the elapsed-time session is forgotten.
        public var sessionResetAfter: Duration = .seconds(60)
        /// Backoff bounds after failed polls.
        public var minimumRetryDelay: Duration = .seconds(5)
        public var maximumRetryDelay: Duration = .seconds(30)
        /// Discord activity rate limit: at most `activityBurst` updates per `activityWindow`.
        public var activityBurst: Int = 5
        public var activityWindow: Duration = .seconds(20)
        /// Delay before re-syncing after a presentation-only settings change, so typing doesn't spam Discord.
        public var settingsDebounce: Duration = .milliseconds(750)
        /// How long to wait before retrying a client ID Discord rejected.
        public var invalidClientIDRetry: Duration = .seconds(300)
        /// Tests only: replaces `settings.effectivePollInterval` so loops run in milliseconds.
        public var pollIntervalOverride: Duration?

        public init() {}
    }

    /// Snapshots with latest-value semantics (`.bufferingNewest(1)`), meant for a single consumer. A new
    /// snapshot is yielded after every state change, starting with the current state when iteration begins.
    public nonisolated let snapshots: AsyncStream<PresenceSnapshot>

    private let snapshotContinuation: AsyncStream<PresenceSnapshot>.Continuation
    private let fetcher: any VitaTitleFetching
    private let resolver: any VitaHostResolving
    private let discord: any DiscordPresenceSink
    private let configuration: Configuration

    /// How long `stop()` waits for Discord to be cleared and disconnected before returning anyway.
    private static let stopTimeout: Duration = .seconds(1)

    // MARK: Run state

    private var isRunning = false
    private var settings = PresenceSettings()
    /// The settings activities are built from. Presentation edits reach it `settingsDebounce` after the last
    /// one (see `presentationDeadline`); everything else in `settings` applies at once.
    private var presentation = PresenceSettings()
    /// When pending presentation edits take effect.
    private var presentationDeadline: ContinuousClock.Instant?
    /// The poll loop; `nil` while stopped or misconfigured. A loop that is replaced or stopped is cancelled,
    /// and a cancelled loop never touches state again, so cancellation is what discards stale poll results.
    private var loopTask: Task<Void, Never>?
    /// `true` while the loop sleeps between ticks; waking it then means starting a fresh loop.
    private var isSleeping = false
    /// Set when a poll is requested mid-tick, so the loop skips the next sleep.
    private var pollRequested = false

    // MARK: Vita state

    private var vitaStatus: VitaStatus = .idle
    private var title: VitaTitle?
    /// `VitaTitle.sessionKey` of the current session, or `nil` when there is none.
    private var sessionKey: String?
    private var sessionStart: Date?
    private var host: String?
    private var lastSuccess: Date?
    private var consecutiveFailures = 0
    /// When the current run of failed polls began.
    private var failingSince: ContinuousClock.Instant?

    // MARK: Discord state

    private var discordStatus: DiscordStatus = .idle
    /// The logged-in user while connected (READY received), otherwise `nil`.
    private var discordUser: DiscordUser?
    /// Identifies the current connection. It changes whenever the connection is dropped or replaced, so late
    /// results that belong to an earlier connection are ignored.
    private var connectionGeneration = 0
    /// What Discord last accepted on the current connection; `.none` while unknown, which is the case from
    /// READY until the first accepted update.
    private var acceptedActivity: DiscordActivity?? = .none
    /// The last payload Discord rejected with `.rpcError`. It isn't resent until the desired activity changes.
    private var rejectedActivity: DiscordActivity?? = .none
    /// After `.invalidClientID`: no connection attempts before this instant (or a client ID change).
    private var invalidClientIDRetryAt: ContinuousClock.Instant?
    /// The connection attempt in progress. It outlives the loop that started it, so a loop that replaces it
    /// (after an address change) waits for the same attempt; only `disconnectDiscord` abandons it.
    private var connectAttempt: Task<DiscordUser, any Error>?
    private var activityBucket: TokenBucket
    /// The one task that sends activities: it waits out the settings debounce and the rate limit, then sends
    /// the newest desired activity until Discord shows it.
    private var syncTask: Task<Void, Never>?
    /// The latest Discord connect or teardown. Each one starts after the previous one finishes, so they never
    /// overlap on the sink.
    private var discordLifecycle: Task<Void, Never>?

    private var lastPublished = PresenceSnapshot.idle

    public init(
        fetcher: any VitaTitleFetching = VitaClient(),
        resolver: any VitaHostResolving = VitaResolver(),
        discord: any DiscordPresenceSink = DiscordIPCClient(),
        configuration: Configuration = Configuration()
    ) {
        (snapshots, snapshotContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.fetcher = fetcher
        self.resolver = resolver
        self.discord = discord
        self.configuration = configuration
        activityBucket = TokenBucket(
            capacity: configuration.activityBurst,
            refillInterval: configuration.activityWindow,
            now: .now
        )
        snapshotContinuation.yield(.idle)
    }

    deinit {
        snapshotContinuation.finish()
    }

    /// The current state.
    public var snapshot: PresenceSnapshot {
        PresenceSnapshot(
            isRunning: isRunning,
            vita: vitaStatus,
            discord: discordStatus,
            title: title,
            sessionStart: sessionStart,
            host: host,
            lastSuccess: lastSuccess,
            publishedActivity: acceptedActivity ?? nil
        )
    }

    /// Starts the loop. If the settings have `issues`, publishes `.misconfigured` and doesn't poll (it stays
    /// "running" so `updateSettings` can fix it). Calling `start` again while running behaves like
    /// `updateSettings`.
    public func start(with settings: PresenceSettings) {
        guard !isRunning else {
            updateSettings(settings)
            return
        }
        isRunning = true
        self.settings = settings
        applyPresentationNow()
        if let issue = settings.issues.first {
            resetVita(status: .misconfigured(issue.message))
        } else {
            activate()
        }
        publish()
    }

    /// Applies new settings while running, or just stores them while stopped. See the type documentation.
    public func updateSettings(_ settings: PresenceSettings) {
        let old = self.settings
        self.settings = settings
        guard isRunning else { return }
        if let issue = settings.issues.first {
            if loopTask != nil { deactivate() }
            resetVita(status: .misconfigured(issue.message))
            publish()
            return
        }
        guard loopTask != nil else {
            // It was misconfigured, and the settings are usable now.
            applyPresentationNow()
            activate()
            publish()
            return
        }

        let clientIDChanged = settings.trimmedClientID != old.trimmedClientID
        let addressChanged = settings.vitaAddress != old.vitaAddress
        if clientIDChanged {
            disconnectDiscord(status: .connecting)
        }
        if addressChanged {
            if let oldAddress = old.vitaAddress, case .mac = oldAddress {
                Task { [resolver] in await resolver.invalidate(oldAddress) }
            }
            resetVita(status: initialVitaStatus)
        }
        if !settings.presentsLike(old) {
            presentationDeadline = .now + configuration.settingsDebounce
            requestSync()
        }
        if clientIDChanged || addressChanged {
            restartLoop()
        } else if settings.effectivePollInterval != old.effectivePollInterval {
            wake()
        }
        publish()
    }

    /// Polls right away (for example after the Mac wakes or the network changes). No-op when stopped.
    public func pollNow() {
        guard loopTask != nil else { return }
        wake()
    }

    /// Stops polling, disconnects Discord (which clears the activity), and publishes `.idle`.
    public func stop() async {
        if isRunning {
            isRunning = false
            deactivate()
            resetVita(status: .idle)
            publish()
        }
        // Also covers a second `stop()` racing the first one: both return once Discord is cleared.
        if let lifecycle = discordLifecycle {
            await Self.wait(atMost: Self.stopTimeout, for: lifecycle)
        }
    }

    // MARK: Run lifecycle

    /// Starts polling with the current settings, which have no issues.
    private func activate() {
        resetVita(status: initialVitaStatus)
        discordStatus = .connecting
        restartLoop()
    }

    /// Stops polling and disconnects Discord in the background.
    private func deactivate() {
        loopTask?.cancel()
        loopTask = nil
        disconnectDiscord(status: .idle)
    }

    /// Replaces the loop (cancelling whatever the old one was doing) with one that ticks right away.
    private func restartLoop() {
        loopTask?.cancel()
        isSleeping = false
        loopTask = Task { await self.runLoop() }
    }

    /// Makes the loop tick as soon as possible without abandoning a tick in progress.
    private func wake() {
        if isSleeping {
            restartLoop()
        } else {
            pollRequested = true
        }
    }

    private func applyPresentationNow() {
        presentation = settings
        presentationDeadline = nil
    }

    private var initialVitaStatus: VitaStatus {
        if case .mac? = settings.vitaAddress { return .resolving }
        return .connecting
    }

    private var nextPollDelay: Duration {
        let interval = configuration.pollIntervalOverride ?? settings.effectivePollInterval
        guard consecutiveFailures > 0 else { return interval }
        let doublings = min(consecutiveFailures - 1, 20)
        let backoff = min(configuration.minimumRetryDelay * (1 << doublings), configuration.maximumRetryDelay)
        return max(backoff, interval)
    }

    // MARK: Loop

    private func runLoop() async {
        while !Task.isCancelled {
            pollRequested = false
            await tick()
            guard !Task.isCancelled else { return }
            if pollRequested { continue }
            isSleeping = true
            try? await Task.sleep(for: nextPollDelay)
            guard !Task.isCancelled else { return }
            isSleeping = false
        }
    }

    private func tick() async {
        await connectDiscordIfNeeded()
        guard !Task.isCancelled else { return }
        await pollVita()
        guard !Task.isCancelled else { return }
        requestSync()
    }

    /// Tick step 1: notices a dropped connection and makes at most one connection attempt, or waits for the
    /// one already in progress.
    private func connectDiscordIfNeeded() async {
        if discordUser != nil {
            let generation = connectionGeneration
            let isConnected = await discord.isConnected
            guard !Task.isCancelled, generation == connectionGeneration else { return }
            if isConnected { return }
            forgetConnection(status: .unavailable(.notConnected))
        }
        let attempt: Task<DiscordUser, any Error>
        if let connectAttempt {
            attempt = connectAttempt
        } else {
            if let retryAt = invalidClientIDRetryAt, ContinuousClock.now < retryAt { return }
            attempt = enqueueConnect(clientID: settings.trimmedClientID)
            connectAttempt = attempt
        }
        let generation = connectionGeneration
        // Cancelling this loop leaves the attempt running for the loop that replaces it.
        let result = await attempt.result
        guard !Task.isCancelled, generation == connectionGeneration else { return }
        connectAttempt = nil
        switch result {
        case .success(let user):
            discordUser = user
            discordStatus = .connected(user)
            // Restore the presence right away instead of after this tick's poll.
            if title != nil { requestSync() }
        case .failure(let error):
            let error = error as? DiscordIPCError ?? .io(String(describing: error))
            if error == .invalidClientID {
                invalidClientIDRetryAt = .now + configuration.invalidClientIDRetry
            }
            discordStatus = .unavailable(error)
        }
        publish()
    }

    /// Tick steps 2 and 3: resolves the address and fetches the title.
    private func pollVita() async {
        guard let address = settings.vitaAddress else { return }
        let host: String
        do {
            host = try await resolver.resolve(address)
        } catch {
            guard !Task.isCancelled else { return }
            await recordFailure(error, address: address)
            return
        }
        guard !Task.isCancelled else { return }
        self.host = host
        if vitaStatus == .resolving { vitaStatus = .connecting }
        publish()

        do {
            let title = try await fetcher.fetchTitle(from: host)
            guard !Task.isCancelled else { return }
            recordSuccess(title)
        } catch {
            guard !Task.isCancelled else { return }
            await recordFailure(error, address: address)
        }
    }

    private func recordSuccess(_ newTitle: VitaTitle) {
        forgetSessionIfExpired(now: .now)
        consecutiveFailures = 0
        failingSince = nil
        if newTitle.sessionKey != sessionKey {
            sessionKey = newTitle.sessionKey
            sessionStart = Date()
        }
        title = newTitle
        lastSuccess = Date()
        vitaStatus = .connected
        publish()
    }

    private func recordFailure(_ error: any Error, address: VitaAddress) async {
        let now = ContinuousClock.now
        consecutiveFailures += 1
        if failingSince == nil { failingSince = now }
        forgetSessionIfExpired(now: now)
        if consecutiveFailures >= configuration.clearAfterFailures {
            title = nil
        }
        let error = error as? VitaConnectionError ?? .other(String(describing: error))
        vitaStatus = .failing(error, failures: consecutiveFailures)
        publish()
        if case .mac = address {
            await resolver.invalidate(address)
        }
    }

    private func forgetSessionIfExpired(now: ContinuousClock.Instant) {
        guard let failingSince, now - failingSince >= configuration.sessionResetAfter else { return }
        sessionKey = nil
        sessionStart = nil
    }

    private func resetVita(status: VitaStatus) {
        vitaStatus = status
        title = nil
        sessionKey = nil
        sessionStart = nil
        host = nil
        lastSuccess = nil
        consecutiveFailures = 0
        failingSince = nil
    }

    // MARK: Discord connection

    /// Connects after any earlier connect or teardown has finished.
    private func enqueueConnect(clientID: String) -> Task<DiscordUser, any Error> {
        let previous = discordLifecycle
        let discord = discord
        let attempt = Task {
            await previous?.value
            try Task.checkCancellation()
            return try await discord.connect(clientID: clientID)
        }
        discordLifecycle = Task { _ = await attempt.result }
        return attempt
    }

    /// Disconnects once any earlier connect or teardown has finished, so a connect that was in flight can't
    /// leave a connection open. `disconnect()` clears the activity itself.
    private func enqueueTeardown() {
        let previous = discordLifecycle
        let discord = discord
        discordLifecycle = Task {
            await previous?.value
            await discord.disconnect()
        }
    }

    /// Forgets the connection on purpose, abandons a connection attempt in progress, and disconnects in the
    /// background.
    private func disconnectDiscord(status: DiscordStatus) {
        connectAttempt?.cancel()
        connectAttempt = nil
        forgetConnection(status: status)
        rejectedActivity = .none
        invalidClientIDRetryAt = nil
        enqueueTeardown()
    }

    /// Forgets the current connection, because it closed or is being replaced. Every connection starts here,
    /// so "last accepted" is unknown again when the next READY arrives.
    private func forgetConnection(status: DiscordStatus) {
        connectionGeneration += 1
        syncTask?.cancel()
        syncTask = nil
        discordUser = nil
        acceptedActivity = .none
        discordStatus = status
    }

    // MARK: Discord sync

    private var desiredActivity: DiscordActivity? {
        title.flatMap { PresenceBuilder.activity(for: $0, settings: presentation, sessionStart: sessionStart) }
    }

    /// Tick step 5, and after anything else that can change the desired activity.
    private func requestSync() {
        guard syncTask == nil, discordUser != nil else { return }
        let generation = connectionGeneration
        syncTask = Task { await self.runSync(generation: generation) }
    }

    private func runSync(generation: Int) async {
        while !Task.isCancelled, generation == connectionGeneration {
            let now = ContinuousClock.now
            if let deadline = presentationDeadline {
                guard now >= deadline else {
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    continue
                }
                presentation = settings
                presentationDeadline = nil
            }
            let desired = desiredActivity
            if acceptedActivity == .some(desired) || rejectedActivity == .some(desired) { break }
            if let wait = activityBucket.consume(now: now) {
                try? await Task.sleep(for: wait)
                continue
            }
            do {
                try await discord.setActivity(desired)
                guard !Task.isCancelled, generation == connectionGeneration else { return }
                acceptedActivity = .some(desired)
                rejectedActivity = .none
                if let discordUser { discordStatus = .connected(discordUser) }
            } catch {
                guard !Task.isCancelled, generation == connectionGeneration else { return }
                let error = error as? DiscordIPCError ?? .io(String(describing: error))
                if case .rpcError = error {
                    rejectedActivity = .some(desired)
                    discordStatus = .unavailable(error)
                } else {
                    forgetConnection(status: .unavailable(error))
                }
            }
            publish()
        }
        // A cancelled sync was already replaced; only a finished one clears its own slot.
        if !Task.isCancelled { syncTask = nil }
    }

    // MARK: Publishing

    private func publish() {
        let current = snapshot
        guard current != lastPublished else { return }
        lastPublished = current
        snapshotContinuation.yield(current)
    }

    /// Waits for `task`, but at most `limit`; the task keeps running in the background afterwards.
    private static func wait(atMost limit: Duration, for task: Task<Void, Never>) async {
        let (finished, continuation) = AsyncStream<Void>.makeStream()
        let waiter = Task {
            await task.value
            continuation.finish()
        }
        let timer = Task {
            try? await Task.sleep(for: limit)
            continuation.finish()
        }
        for await _ in finished {}
        waiter.cancel()
        timer.cancel()
    }
}

private extension PresenceSettings {
    /// `true` when both settings build the same activity from the same title.
    func presentsLike(_ other: PresenceSettings) -> Bool {
        stateText == other.stateText
            && largeImageKey == other.largeImageKey
            && showElapsedTime == other.showElapsedTime
            && showLiveArea == other.showLiveArea
    }
}

import ArtworkKit
import DiscordIPC
import Foundation
import VitaKit

/// The poll loop shared by the app and the CLI: polls the Vita, keeps Discord's activity in sync, and
/// publishes `PresenceSnapshot`s.
///
/// Behaviour:
/// - **Loop:** while running, each tick (1) resolves the address, (2) fetches the title, (3) computes the
///   desired activity with `PresenceBuilder`, and (4) opens Discord only when that activity exists and syncs
///   it. A handshake by itself makes Discord show the application's name, so Discord stays closed while the
///   Vita is being looked for and is closed again when there is nothing to show. After `.invalidClientID`,
///   Discord isn't retried until the client ID changes or `invalidClientIDRetry` passes. Ticks are
///   `settings.effectivePollInterval` apart while the Vita answers. After failures they back off
///   exponentially from `minimumRetryDelay` to `maximumRetryDelay`, never faster than the poll interval
///   would be.
/// - **Sessions:** a session starts (sessionStart = now) when the first title arrives or
///   `VitaTitle.sessionKey` changes. If the Vita has been unreachable for `sessionResetAfter`, the session is
///   forgotten, so the next title starts a new one. "No previous title" is `nil`, never `""`, so the first
///   LiveArea packet starts a session.
/// - **Failures:** a single failed poll keeps the presence and the Discord connection. The title is cleared,
///   and the helper exits, only after `clearAfterFailures` consecutive failures and `clearAfterUnreachable`
///   of silence, so a couple of missed polls do not drop the game. An empty activity would leave the
///   application's name up. An automatic or MAC address
///   starts out `.resolving` and is invalidated in the resolver after every failure.
/// - **Artwork:** when the title changes (or `showGameArtwork` is turned on), one lookup for its artwork
///   starts in the background. The sync waits up to `artworkGrace` for that lookup so a quick one is sent
///   once, text and image together; a slower lookup sends the text when the grace ends and the image when it
///   arrives. A miss (`nil`) is tried again after `artworkRetryInterval` while that title is current. Hits are
///   kept until `stop()`. A lookup is abandoned, and its result ignored, when the title changes or goes away,
///   artwork is turned off, a custom image is set, or the controller stops. The LiveArea and system apps are
///   never looked up, and nothing is looked up while `showGameArtwork` is off or a custom image is set.
/// - **Discord sync:** sends only when the desired activity differs from what was last accepted on the
///   current connection, and always after a (re)connect: each READY resets "last accepted" to unknown.
///   Rate-limited by a `SlidingWindowLimiter` (`activityBurst` sends in any `activityWindow`); while limited,
///   only the newest desired activity is sent once a slot is free. Nothing to show (no title, or the LiveArea
///   while it is hidden) closes Discord instead of sending a clear: a clear leaves the application's name up.
///   A payload rejected with `.rpcError` isn't retried until the desired activity changes, except an https
///   image: that update is sent again at once without its images, and the images are tried again after
///   `remoteImageRetry`. `.notConnected`, `.timedOut`, `.io` and `.closedByDiscord` mark Discord as
///   disconnected; the next tick reconnects when there is still an activity to show.
/// - **Settings changes:** a different client ID disconnects Discord and reconnects immediately. A different
///   address resets the resolver, failure count, title and session, then polls immediately; a Discord
///   connection attempt in progress carries on. Presentation-only changes (state text, image, toggles)
///   re-sync from the last title after `settingsDebounce`. A different poll interval takes effect at once.
///   Results of a poll that started before an address change are discarded.
/// - **Responsiveness:** `pollNow()`, `updateSettings(_:)` and `stop()` interrupt the sleep between ticks
///   right away. `stop()` returns within about a second even mid-poll: it cancels the loop, disconnects
///   Discord (which drops the activity by closing the socket), and publishes `.idle`.
public actor PresenceController {
    public struct Configuration: Sendable {
        /// Consecutive failed polls before the presence can be cleared.
        public var clearAfterFailures: Int = 2
        /// How long the Vita must stay unreachable, as well as missing `clearAfterFailures` polls, before
        /// Discord is dropped. `.zero` drops as soon as the failure count is reached.
        public var clearAfterUnreachable: Duration = .seconds(60)
        /// How long the Vita may be unreachable before the elapsed-time session is forgotten.
        public var sessionResetAfter: Duration = .seconds(60)
        /// Backoff bounds after failed polls.
        public var minimumRetryDelay: Duration = .seconds(5)
        public var maximumRetryDelay: Duration = .seconds(30)
        /// Discord activity rate limit: at most `activityBurst` updates in any `activityWindow`.
        public var activityBurst: Int = 5
        public var activityWindow: Duration = .seconds(20)
        /// How long a game switch waits for artwork before sending the text alone. `0` sends the text at once.
        public var artworkGrace: Duration = .milliseconds(1500)
        /// How long a miss is remembered before the same title is looked up again.
        public var artworkRetryInterval: Duration = .seconds(600)
        /// How long to leave https images off after Discord rejects an update that carried them.
        public var remoteImageRetry: Duration = .seconds(60)
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
    /// Looks up the running game's artwork for the large image.
    private let artwork: any ArtworkResolving
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
    private var activityLimiter: SlidingWindowLimiter
    /// Until this instant, https images are left off an update Discord rejected.
    private var remoteImageRetryAt: ContinuousClock.Instant?
    /// The one task that sends activities: it waits out the settings debounce and the rate limit, then sends
    /// the newest desired activity until Discord shows it.
    private var syncTask: Task<Void, Never>?
    /// The latest Discord connect or teardown. Each one starts after the previous one finishes, so they never
    /// overlap on the sink.
    private var discordLifecycle: Task<Void, Never>?

    // MARK: Artwork state

    /// Lookups finished during this run, by title.
    private var artworkResults: [ArtworkKey: ArtworkRecord] = [:]
    /// While set, a sync waits until this instant or until the lookup in progress finishes.
    private var artworkGraceDeadline: ContinuousClock.Instant?
    /// Wakes a sync that is waiting out `artworkGrace`.
    private var graceWaiter: CheckedContinuation<Void, Never>?
    /// Invalidates a grace timer that a newer lookup or a finished one has replaced.
    private var graceGeneration = 0
    /// The lookup in progress, if any.
    private var artworkLookup: ArtworkLookup?
    /// Identifies the latest lookup. It changes whenever a lookup is started or abandoned, so a result that
    /// arrives after its lookup was abandoned is ignored.
    private var artworkGeneration = 0

    private var lastPublished = PresenceSnapshot.idle

    public init(
        fetcher: any VitaTitleFetching = VitaClient(),
        resolver: any VitaHostResolving = VitaResolver(),
        discord: any DiscordPresenceSink = DiscordIPCClient(),
        artwork: any ArtworkResolving = ArtworkResolver(),
        configuration: Configuration = Configuration()
    ) {
        (snapshots, snapshotContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.fetcher = fetcher
        self.resolver = resolver
        self.discord = discord
        self.artwork = artwork
        self.configuration = configuration
        activityLimiter = SlidingWindowLimiter(
            limit: configuration.activityBurst,
            window: configuration.activityWindow
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
            publishedActivity: acceptedActivity ?? nil,
            artwork: currentArtwork
        )
    }

    /// Starts the loop. If the settings have `issues`, publishes `.misconfigured` and doesn't poll (it stays
    /// "running" so `updateSettings` can fix it). Calling `start` again while running behaves like
    /// `updateSettings`.
    public func start(with settings: PresenceSettings) async {
        guard !isRunning else {
            updateSettings(settings)
            return
        }
        await resolver.retryDiscovery()
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

    /// Points automatic discovery at a saved Vita. The next poll uses `host`, and a scan can follow
    /// `macAddress` after that host stops answering.
    public func rememberVita(host: String?, macAddress: MACAddress?) async {
        await resolver.remember(host: host, macAddress: macAddress)
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

        let clientIDChanged = settings.effectiveClientID != old.effectiveClientID
        let addressChanged = settings.vitaAddress != old.vitaAddress
        if clientIDChanged {
            disconnectDiscord(status: .connecting)
        }
        if addressChanged {
            if let oldAddress = old.vitaAddress, oldAddress.needsResolving {
                Task { [resolver] in await resolver.invalidate(oldAddress) }
            }
            resetVita(status: initialVitaStatus)
        }
        if !settings.presentsLike(old) {
            presentationDeadline = .now + configuration.settingsDebounce
            requestSync()
        }
        if desiredActivity == nil, discordUser == nil, connectAttempt == nil, discordStatus == .connecting {
            // A client-ID change marks Discord as connecting before this. With nothing to show, that
            // connection is not started.
            discordStatus = .idle
        }
        if clientIDChanged || addressChanged {
            restartLoop()
        } else if settings.effectivePollInterval != old.effectivePollInterval {
            wake()
        }
        updateArtworkLookup()
        publish()
    }

    /// Polls right away (for example after the Mac wakes or the network changes). No-op when stopped.
    public func pollNow() async {
        guard loopTask != nil else { return }
        await resolver.retryDiscovery()
        wake()
    }

    /// Stops polling, disconnects Discord (which clears the activity), and publishes `.idle`.
    public func stop() async {
        if isRunning {
            isRunning = false
            deactivate()
            resetVita(status: .idle)
            artworkResults.removeAll()
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

    /// `.resolving` ("Looking for your Vita…") until an automatic or MAC address is resolved, otherwise
    /// `.connecting`.
    private var initialVitaStatus: VitaStatus {
        if settings.vitaAddress?.needsResolving == true { return .resolving }
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
        // A dropped socket is noticed before the poll, so putting the game back does not wait on a fetch.
        // The first real handshake still waits: there is nothing to show until a poll has succeeded.
        if await discordDroppedWhileShowing() {
            await reflectDiscord()
            guard !Task.isCancelled else { return }
        }
        await pollVita()
        guard !Task.isCancelled else { return }
        await reflectDiscord()
    }

    /// True when Discord was showing a title and the socket has since closed.
    private func discordDroppedWhileShowing() async -> Bool {
        guard desiredActivity != nil, discordUser != nil else { return false }
        return await !discord.isConnected
    }

    /// Opens Discord and publishes the activity when there is one to show. Closes it otherwise, so a
    /// handshake never leaves the application's name up on its own.
    private func reflectDiscord() async {
        guard desiredActivity != nil else {
            dropDiscordIfOpen()
            return
        }
        // A quick artwork lookup can ride along with the first update. Waiting before the handshake keeps
        // Discord from showing the application's name during that pause.
        await pauseForArtworkGrace()
        guard !Task.isCancelled, desiredActivity != nil else {
            dropDiscordIfOpen()
            return
        }
        await connectDiscordIfNeeded()
        guard !Task.isCancelled else { return }
        requestSync()
    }

    /// Closes an established Discord connection when there is nothing to show. A handshake that has not
    /// finished is left running: an address change can still use it, and it has not shown the application's
    /// name yet.
    private func dropDiscordIfOpen() {
        guard discordUser != nil else { return }
        disconnectDiscord(status: .idle)
        publish()
    }

    /// Notices a dropped connection and makes at most one connection attempt, or waits for the one already
    /// in progress. Called only when there is an activity to send.
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
            guard let desired = desiredActivity else { return }
            discordStatus = .connecting
            publish()
            attempt = enqueueConnect(clientID: settings.effectiveClientID, activity: desired)
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
            // The helper publishes the game before it reports ready. Sync still runs so a title that
            // changed during the handshake, or a sink that only handshakes, is caught up at once.
            requestSync()
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
        updateArtworkLookup()
        publish()
    }

    private func recordFailure(_ error: any Error, address: VitaAddress) async {
        let now = ContinuousClock.now
        consecutiveFailures += 1
        if failingSince == nil { failingSince = now }
        forgetSessionIfExpired(now: now)
        let quietLongEnough = configuration.clearAfterUnreachable <= .zero
            || failingSince.map { now - $0 >= configuration.clearAfterUnreachable } == true
        if consecutiveFailures >= configuration.clearAfterFailures, quietLongEnough {
            title = nil
            updateArtworkLookup()
        }
        let error = error as? VitaConnectionError ?? .other(String(describing: error))
        vitaStatus = .failing(error, failures: consecutiveFailures)
        publish()
        if address.needsResolving {
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
        updateArtworkLookup()
    }

    // MARK: Discord connection

    /// Connects after any earlier connect or teardown has finished, and publishes `activity` with the handshake.
    private func enqueueConnect(clientID: String, activity: DiscordActivity) -> Task<DiscordUser, any Error> {
        let previous = discordLifecycle
        let discord = discord
        let attempt = Task {
            await previous?.value
            try Task.checkCancellation()
            return try await discord.connect(clientID: clientID, activity: activity)
        }
        discordLifecycle = Task { _ = await attempt.result }
        return attempt
    }

    /// Disconnects once any earlier connect or teardown has finished, so a connect that was in flight can't
    /// leave a connection open. `disconnect()` closes the socket and does not send an empty activity.
    private func enqueueTeardown() {
        let previous = discordLifecycle
        let discord = discord
        discordLifecycle = Task {
            await previous?.value
            await discord.disconnect()
        }
    }

    /// Forgets the connection on purpose, abandons a connection attempt in progress, and disconnects in the
    /// background. `cancelSync` is false when the running sync itself decided there is nothing to show, so
    /// it can finish without cancelling itself.
    private func disconnectDiscord(status: DiscordStatus, cancelSync: Bool = true) {
        connectAttempt?.cancel()
        connectAttempt = nil
        if cancelSync {
            forgetConnection(status: status)
        } else {
            connectionGeneration += 1
            discordUser = nil
            acceptedActivity = .none
            remoteImageRetryAt = nil
            discordStatus = status
            syncTask = nil
        }
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
        remoteImageRetryAt = nil
        discordStatus = status
    }

    // MARK: Discord sync

    private var desiredActivity: DiscordActivity? {
        guard let title else { return nil }
        let activity = PresenceBuilder.activity(
            for: title,
            settings: presentation,
            sessionStart: sessionStart,
            artwork: currentArtwork
        )
        if let retryAt = remoteImageRetryAt, ContinuousClock.now < retryAt {
            return Self.strippingRemoteImages(activity)
        }
        return activity
    }

    /// After anything that can change the desired activity. Also runs while Discord is closed when a pending
    /// presentation change may produce an activity, so turning the LiveArea back on reconnects.
    private func requestSync() {
        guard syncTask == nil else { return }
        guard discordUser != nil || connectAttempt != nil || presentationDeadline != nil || desiredActivity != nil
        else { return }
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
            await pauseForArtworkGrace()
            guard !Task.isCancelled, generation == connectionGeneration else { return }
            let desired = desiredActivity
            if desired == nil {
                // Nothing to show. Close the socket. An empty activity would leave the application's name up.
                if discordUser != nil {
                    disconnectDiscord(status: .idle, cancelSync: false)
                    publish()
                } else if !Task.isCancelled {
                    syncTask = nil
                }
                return
            }
            if discordUser == nil {
                await connectDiscordIfNeeded()
                guard !Task.isCancelled, generation == connectionGeneration, discordUser != nil else {
                    if !Task.isCancelled { syncTask = nil }
                    return
                }
            }
            if acceptedActivity == .some(desired) || rejectedActivity == .some(desired) { break }
            if let wait = activityLimiter.consume(now: ContinuousClock.now) {
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
                if case .rpcError = error, Self.hasRemoteImage(desired) {
                    // The picture was refused. Show the game at once without it, and try the picture later.
                    remoteImageRetryAt = .now + configuration.remoteImageRetry
                    continue
                }
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

    // MARK: Artwork

    /// What the current title's artwork is looked up and kept by, or `nil` when it needs none: no title, the
    /// LiveArea, a system app, artwork turned off, or a custom image (which replaces the lookup).
    private var artworkKey: ArtworkKey? {
        guard let title, settings.showGameArtwork, settings.largeImageKey.isBlank else { return nil }
        switch title.kind {
        case .liveArea, .systemApp: return nil
        case .adrenalineMenu, .vitaGame, .pspGame, .ps1Game, .other:
            return ArtworkKey(titleID: title.titleID, contentID: title.contentID)
        }
    }

    /// The current title's artwork, once its lookup has found one.
    private var currentArtwork: URL? {
        guard let key = artworkKey, let record = artworkResults[key] else { return nil }
        return record.url
    }

    /// `true` when `key` has no result worth keeping: nothing remembered, or a miss older than
    /// `artworkRetryInterval`.
    private func needsLookup(_ key: ArtworkKey) -> Bool {
        guard let record = artworkResults[key] else { return true }
        guard record.url == nil else { return false }
        return ContinuousClock.now - record.checkedAt >= configuration.artworkRetryInterval
    }

    /// Starts looking up the current title's artwork when it is needed and not known yet, and abandons a
    /// lookup that is no longer needed. Called after every change to the title or the settings.
    private func updateArtworkLookup() {
        let key = artworkKey
        guard key != artworkLookup?.key else { return }
        artworkLookup?.task.cancel()
        artworkLookup = nil
        artworkGeneration += 1
        guard let key, let title, needsLookup(key) else {
            artworkGraceDeadline = nil
            endArtworkGraceWait()
            return
        }
        if configuration.artworkGrace > .zero {
            artworkGraceDeadline = ContinuousClock.now + configuration.artworkGrace
        } else {
            artworkGraceDeadline = nil
        }
        endArtworkGraceWait()
        let generation = artworkGeneration
        let task = Task {
            let url = await self.artwork.artwork(for: title)
            self.finishArtworkLookup(generation: generation, key: key, url: url)
        }
        artworkLookup = ArtworkLookup(key: key, task: task)
    }

    /// Keeps a lookup's result and shows it, unless the lookup was abandoned meanwhile.
    private func finishArtworkLookup(generation: Int, key: ArtworkKey, url: URL?) {
        guard generation == artworkGeneration else { return }
        artworkLookup = nil
        artworkGraceDeadline = nil
        artworkResults[key] = ArtworkRecord(url: url, checkedAt: .now)
        endArtworkGraceWait()
        publish()
        requestSync()
    }

    /// Holds the sync until the artwork lookup finishes or `artworkGrace` runs out, so a quick lookup is sent
    /// once. Returns immediately when nothing is being waited for.
    private func pauseForArtworkGrace() async {
        guard let deadline = artworkGraceDeadline, artworkLookup != nil, ContinuousClock.now < deadline else { return }
        graceGeneration += 1
        let generation = graceGeneration
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            graceWaiter = continuation
            Task {
                try? await Task.sleep(until: deadline, clock: .continuous)
                self.artworkGraceExpired(generation: generation)
            }
        }
    }

    private func artworkGraceExpired(generation: Int) {
        guard generation == graceGeneration else { return }
        artworkGraceDeadline = nil
        endArtworkGraceWait()
    }

    /// Resumes a sync waiting on artwork grace. A later grace timer from the wait that was resumed is ignored.
    private func endArtworkGraceWait() {
        graceGeneration += 1
        graceWaiter?.resume()
        graceWaiter = nil
    }

    /// `true` when `activity` carries an https image Discord has to fetch.
    private static func hasRemoteImage(_ activity: DiscordActivity?) -> Bool {
        let images = [activity?.assets?.largeImage, activity?.assets?.smallImage]
        return images.contains { $0?.lowercased().hasPrefix("https://") == true }
    }

    /// `activity` with its https images removed. Asset keys are kept.
    private static func strippingRemoteImages(_ activity: DiscordActivity?) -> DiscordActivity? {
        guard var activity, var assets = activity.assets else { return activity }
        if assets.largeImage?.lowercased().hasPrefix("https://") == true {
            assets.largeImage = nil
            assets.largeText = nil
        }
        if assets.smallImage?.lowercased().hasPrefix("https://") == true {
            assets.smallImage = nil
            assets.smallText = nil
        }
        activity.assets = assets.largeImage == nil && assets.smallImage == nil ? nil : assets
        return activity
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

/// A finished artwork lookup.
private struct ArtworkRecord {
    var url: URL?
    var checkedAt: ContinuousClock.Instant
}

/// What artwork is looked up and kept by; the resolver caches it by the same two IDs.
private struct ArtworkKey: Hashable {
    var titleID: String
    var contentID: String?
}

/// An artwork lookup in progress.
private struct ArtworkLookup {
    var key: ArtworkKey
    var task: Task<Void, Never>
}

private extension PresenceSettings {
    /// `true` when both settings build the same activity from the same title.
    func presentsLike(_ other: PresenceSettings) -> Bool {
        stateText == other.stateText
            && largeImageKey == other.largeImageKey
            && showElapsedTime == other.showElapsedTime
            && showLiveArea == other.showLiveArea
            && showGameArtwork == other.showGameArtwork
    }
}

private extension VitaAddress {
    /// `true` for addresses the resolver has to look up (found automatically, or by MAC address).
    var needsResolving: Bool {
        if case .ipv4 = self { return false }
        return true
    }
}

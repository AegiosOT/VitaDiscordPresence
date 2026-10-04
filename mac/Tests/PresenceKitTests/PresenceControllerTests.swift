import DiscordIPC
import Foundation
import Testing
import VitaKit
@testable import PresenceKit

@Suite struct PresenceControllerTests {
    // MARK: Happy path

    @Test func startConnectsPollsAndSendsTheActivity() async throws {
        try await withController { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.publishedActivity != nil })

            let snapshot = await h.controller.snapshot
            let start = try #require(snapshot.sessionStart)
            let sent = try #require(await h.discord.acceptedActivities.first ?? nil)
            #expect(sent.details == "Persona 4 Golden")
            #expect(sent.timestamps?.start == milliseconds(start))
            #expect(snapshot.publishedActivity == sent)
            #expect(snapshot.isRunning)
            #expect(snapshot.vita == .connected)
            #expect(snapshot.discord == .connected(testUser))
            #expect(snapshot.title == persona)
            #expect(snapshot.host == "192.168.1.20")
            #expect(snapshot.lastSuccess != nil)
            #expect(await h.discord.connectAttempts == [validClientID])
            #expect(await h.fetcher.calls.first?.host == "192.168.1.20")
        }
    }

    @Test func identicalPollsDontResend() async throws {
        try await withController { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.fetcher.callCount >= 6 })
            #expect(await h.discord.attempts.count == 1)
            #expect(await h.discord.connectAttempts.count == 1)
        }
    }

    @Test func titleChangeSendsANewActivityWithANewSessionStart() async throws {
        let fetcher = FakeFetcher(.title(persona))
        try await withController(fetcher) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.publishedActivity?.details == persona.name })
            let firstStart = try #require(await h.controller.snapshot.sessionStart)

            try await Task.sleep(for: .milliseconds(5))
            await fetcher.setSteps(.title(gravityRush))
            #expect(await eventually { await h.controller.snapshot.publishedActivity?.details == gravityRush.name })

            let secondStart = try #require(await h.controller.snapshot.sessionStart)
            #expect(secondStart > firstStart)
            let sent = await h.discord.acceptedActivities
            #expect(sent.map { $0?.details } == [persona.name, gravityRush.name])
            #expect(sent.last??.timestamps?.start == milliseconds(secondStart))
        }
    }

    @Test func sameTitleIDKeepsTheSessionWhenTheNameChanges() async throws {
        let fetcher = FakeFetcher(.title(persona))
        try await withController(fetcher) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.publishedActivity != nil })
            let start = try #require(await h.controller.snapshot.sessionStart)

            let renamed = VitaTitle(index: 7, titleID: persona.titleID, name: "Persona 4 Golden (EU)")
            await fetcher.setSteps(.title(renamed))
            #expect(await eventually { await h.controller.snapshot.publishedActivity?.details == renamed.name })
            #expect(await h.controller.snapshot.sessionStart == start)
        }
    }

    @Test func firstLiveAreaPacketStartsASession() async throws {
        try await withController(FakeFetcher(.title(.liveArea))) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.publishedActivity != nil })
            let snapshot = await h.controller.snapshot
            let start = try #require(snapshot.sessionStart)
            #expect(snapshot.title == .liveArea)
            #expect(snapshot.publishedActivity?.details == "In the LiveArea")
            #expect(snapshot.publishedActivity?.timestamps?.start == milliseconds(start))
        }
    }

    @Test func leavingTheLiveAreaStartsANewSession() async throws {
        let fetcher = FakeFetcher(.title(.liveArea))
        try await withController(fetcher) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.publishedActivity?.details == "In the LiveArea" })
            let liveAreaStart = try #require(await h.controller.snapshot.sessionStart)

            try await Task.sleep(for: .milliseconds(5))
            await fetcher.setSteps(.title(persona))
            #expect(await eventually { await h.controller.snapshot.publishedActivity?.details == persona.name })
            let gameStart = try #require(await h.controller.snapshot.sessionStart)
            #expect(gameStart > liveAreaStart)
        }
    }

    // MARK: Failures and sessions

    @Test func aSingleFailureKeepsThePresence() async throws {
        let fetcher = FakeFetcher(.title(persona), .failure(.refused), .title(persona))
        await fetcher.pause(atCall: 3)
        try await withController(fetcher) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await fetcher.callCount == 3 })

            let failing = await h.controller.snapshot
            #expect(failing.vita == .failing(.refused, failures: 1))
            #expect(failing.title == persona)
            #expect(failing.publishedActivity?.details == persona.name)
            #expect(await h.discord.attempts.count == 1)

            await fetcher.resume()
            #expect(await eventually { await h.controller.snapshot.vita == .connected })
            #expect(await stays(for: .milliseconds(100)) { await h.discord.attempts.count == 1 })
        }
    }

    @Test func clearAfterFailuresClearsThePresence() async throws {
        let fetcher = FakeFetcher(.title(persona), .failure(.timedOut))
        await fetcher.pause(atCall: 4)
        try await withController(fetcher, configure: { $0.clearAfterFailures = 3 }) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await fetcher.callCount == 4 })

            // Two failures: still shown.
            let afterTwo = await h.controller.snapshot
            #expect(afterTwo.vita == .failing(.timedOut, failures: 2))
            #expect(afterTwo.title == persona)
            #expect(await h.discord.acceptedActivities.count == 1)

            // The third failure clears it.
            await fetcher.resume()
            #expect(await eventually { await h.discord.acceptedActivities.last == .some(nil) })
            let cleared = await h.controller.snapshot
            #expect(cleared.title == nil)
            #expect(cleared.publishedActivity == nil)
            #expect(cleared.vita == .failing(.timedOut, failures: 3))
            #expect(await h.discord.acceptedActivities.map { $0?.details } == [persona.name, nil])
        }
    }

    @Test func vitaBackWithinSessionResetKeepsTheSessionStart() async throws {
        let fetcher = FakeFetcher(.title(persona))
        try await withController(fetcher, configure: { $0.sessionResetAfter = .seconds(30) }) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.publishedActivity != nil })
            let start = try #require(await h.controller.snapshot.sessionStart)

            await fetcher.setSteps(.failure(.timedOut))
            #expect(await eventually { await h.discord.acceptedActivities.last == .some(nil) })
            #expect(await h.controller.snapshot.title == nil)

            await fetcher.setSteps(.title(persona))
            #expect(await eventually { await h.controller.snapshot.publishedActivity != nil })
            #expect(await h.controller.snapshot.sessionStart == start)
            #expect(await h.discord.acceptedActivities.last??.timestamps?.start == milliseconds(start))
        }
    }

    @Test func vitaBackAfterSessionResetStartsANewSession() async throws {
        let fetcher = FakeFetcher(.title(persona))
        try await withController(fetcher, configure: { $0.sessionResetAfter = .milliseconds(150) }) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.publishedActivity != nil })
            let start = try #require(await h.controller.snapshot.sessionStart)

            await fetcher.setSteps(.failure(.timedOut))
            #expect(await eventually { await h.controller.snapshot.sessionStart == nil })

            await fetcher.setSteps(.title(persona))
            #expect(await eventually { await h.controller.snapshot.publishedActivity != nil })
            let newStart = try #require(await h.controller.snapshot.sessionStart)
            #expect(newStart > start)
            #expect(await h.discord.acceptedActivities.last??.timestamps?.start == milliseconds(newStart))
        }
    }

    @Test func answerAfterALongBackoffStartsANewSession() async throws {
        // The only failed poll comes before `sessionResetAfter` has passed, so the answer after the backoff is
        // what finds the session expired.
        let fetcher = FakeFetcher(.title(persona), .failure(.timedOut), .title(persona))
        try await withController(fetcher, configure: {
            $0.sessionResetAfter = .milliseconds(150)
            $0.minimumRetryDelay = .milliseconds(300)
            $0.maximumRetryDelay = .milliseconds(300)
        }) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.publishedActivity != nil })
            let start = try #require(await h.controller.snapshot.sessionStart)

            #expect(await eventually { await h.controller.snapshot.sessionStart.map { $0 > start } ?? false })
            let newStart = try #require(await h.controller.snapshot.sessionStart)
            #expect(await eventually {
                await h.discord.acceptedActivities.last??.timestamps?.start == milliseconds(newStart)
            })
        }
    }

    @Test func backoffGrowsExponentiallyUpToTheMaximum() async throws {
        let fetcher = FakeFetcher(.failure(.refused))
        try await withController(fetcher, configure: {
            $0.pollIntervalOverride = .milliseconds(10)
            $0.minimumRetryDelay = .milliseconds(50)
            $0.maximumRetryDelay = .milliseconds(100)
        }) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await fetcher.callCount >= 5 })
            let times = await fetcher.calls.map(\.at)
            let gaps = zip(times, times.dropFirst()).map { $1 - $0 }
            #expect(gaps[0] >= .milliseconds(50))
            #expect(gaps[1] >= .milliseconds(100))
            #expect(gaps[2] >= .milliseconds(100))
            #expect(gaps[3] >= .milliseconds(100))
            #expect(gaps[3] < .milliseconds(190), "the delay is capped at maximumRetryDelay")
        }
    }

    @Test func backoffIsNeverFasterThanThePollInterval() async throws {
        let fetcher = FakeFetcher(.failure(.refused))
        try await withController(fetcher, configure: { $0.pollIntervalOverride = .milliseconds(120) }) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await fetcher.callCount >= 3 })
            let times = await fetcher.calls.map(\.at)
            #expect(times[1] - times[0] >= .milliseconds(120))
            #expect(times[2] - times[1] >= .milliseconds(120))
        }
    }

    @Test func macAddressIsResolvedAndInvalidatedAfterEveryFailure() async throws {
        let fetcher = FakeFetcher(.failure(.timedOut))
        let resolver = FakeResolver(macHost: "192.168.1.77")
        var settings = PresenceSettings.valid
        settings.address = "a4:5e:60:01:02:03"
        let mac = try #require(settings.vitaAddress)
        try await withController(fetcher, resolver: resolver) { h in
            await h.controller.start(with: settings)
            #expect(await eventually { await resolver.invalidated.count >= 2 })
            #expect(await resolver.invalidated.allSatisfy { $0 == mac })
            #expect(await fetcher.calls.allSatisfy { $0.host == "192.168.1.77" })
            #expect(await h.controller.snapshot.host == "192.168.1.77")
        }
    }

    @Test func macAddressStartsByResolving() async throws {
        let resolver = FakeResolver()
        await resolver.fail(with: .unresolvedAddress("No Vita with that MAC address"))
        await resolver.setDelay(.milliseconds(300))
        var settings = PresenceSettings.valid
        settings.address = "a4:5e:60:01:02:03"
        let fetcher = FakeFetcher(.title(persona))
        try await withController(fetcher, resolver: resolver, configure: { $0.pollIntervalOverride = .seconds(30) }) { h in
            await h.controller.start(with: settings)
            #expect(await eventually { await resolver.resolved.count == 1 })
            #expect(await h.controller.snapshot.vita == .resolving)
            let error = VitaConnectionError.unresolvedAddress("No Vita with that MAC address")
            #expect(await eventually { await h.controller.snapshot.vita == .failing(error, failures: 1) })
            #expect(await fetcher.callCount == 0)
            #expect(await h.controller.snapshot.host == nil)
        }
    }

    @Test func ipv4AddressIsNeverInvalidated() async throws {
        try await withController(FakeFetcher(.failure(.refused))) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.fetcher.callCount >= 3 })
            #expect(await h.resolver.invalidated.isEmpty)
            guard case .failing(.refused, let failures) = await h.controller.snapshot.vita else {
                Issue.record("expected a failing Vita")
                return
            }
            #expect(failures >= 3)
        }
    }

    // MARK: Discord

    @Test func discordReconnectResendsTheActivity() async throws {
        try await withController { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.publishedActivity != nil })

            await h.discord.dropConnection()
            #expect(await eventually { await h.discord.acceptedActivities.count == 2 })
            let sent = await h.discord.acceptedActivities
            #expect(sent[0] == sent[1])
            #expect(await h.discord.connectAttempts == [validClientID, validClientID])
            #expect(await eventually { await h.controller.snapshot.discord == .connected(testUser) })
            #expect(await h.controller.snapshot.publishedActivity == sent[1])
        }
    }

    @Test func statusIsConnectedAsSoonAsDiscordIsReady() async throws {
        let discord = FakeDiscord()
        await discord.setUpdatesHang(true)
        try await withController(discord: discord) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.discord == .connected(testUser) })
            #expect(await h.controller.snapshot.publishedActivity == nil)
            await discord.setUpdatesHang(false)
        }
    }

    @Test func reconnectResendsWithoutWaitingForTheVitaPoll() async throws {
        let fetcher = FakeFetcher(.title(persona))
        try await withController(fetcher, configure: { $0.pollIntervalOverride = .seconds(30) }) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.publishedActivity != nil })

            await fetcher.pause(atCall: 2)
            await h.discord.dropConnection()
            await h.controller.pollNow()
            #expect(await eventually { await h.discord.acceptedActivities.count == 2 })
            #expect(await fetcher.callCount <= 2, "the resend didn't wait for the paused poll")
            await fetcher.resume()
        }
    }

    @Test func droppedConnectionDuringASendReconnectsAndResends() async throws {
        let fetcher = FakeFetcher(.title(persona))
        let discord = FakeDiscord()
        await discord.reject { $0?.details == gravityRush.name ? .io("Broken pipe") : nil }
        try await withController(fetcher, discord: discord) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.publishedActivity != nil })

            await fetcher.setSteps(.title(gravityRush))
            #expect(await eventually { await discord.connectAttempts.count >= 2 })
            await discord.reject { _ in nil }
            #expect(await eventually { await h.controller.snapshot.publishedActivity?.details == gravityRush.name })
            #expect(await h.controller.snapshot.discord == .connected(testUser))
        }
    }

    @Test func rejectedPayloadIsNotRetriedUntilTheActivityChanges() async throws {
        let fetcher = FakeFetcher(.title(persona))
        let discord = FakeDiscord()
        let rejection = DiscordIPCError.rpcError(code: 4000, message: "child \"activity\" fails")
        await discord.reject { $0?.details == persona.name ? rejection : nil }
        try await withController(fetcher, discord: discord) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.discord == .unavailable(rejection) })
            #expect(await eventually { await fetcher.callCount >= 6 })
            #expect(await discord.attempts.count == 1)
            #expect(await discord.connectAttempts.count == 1, "a rejection keeps the connection")

            await fetcher.setSteps(.title(gravityRush))
            #expect(await eventually { await h.controller.snapshot.publishedActivity?.details == gravityRush.name })
            #expect(await h.controller.snapshot.discord == .connected(testUser))
            #expect(await discord.attempts.count == 2)
        }
    }

    @Test func invalidClientIDIsNotRetriedEveryTick() async throws {
        let discord = FakeDiscord()
        await discord.failConnects(with: .invalidClientID)
        try await withController(discord: discord) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.discord == .unavailable(.invalidClientID) })
            #expect(await eventually { await h.fetcher.callCount >= 8 }, "the Vita is still polled")
            #expect(await discord.connectAttempts == [validClientID])

            // A different client ID is tried right away.
            await discord.failConnects(with: nil)
            var settings = PresenceSettings.valid
            settings.clientID = "987654321098765432"
            await h.controller.updateSettings(settings)
            #expect(await eventually { await h.controller.snapshot.discord == .connected(testUser) })
            #expect(await discord.connectAttempts == [validClientID, "987654321098765432"])
            #expect(await eventually { await h.controller.snapshot.publishedActivity?.details == persona.name })
        }
    }

    @Test func rejectedPayloadIsRetriedForANewClientID() async throws {
        let discord = FakeDiscord()
        let rejection = DiscordIPCError.rpcError(code: 4000, message: "child \"activity\" fails")
        await discord.reject { $0?.details == persona.name ? rejection : nil }
        try await withController(discord: discord) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.discord == .unavailable(rejection) })

            var settings = PresenceSettings.valid
            settings.clientID = "987654321098765432"
            await h.controller.updateSettings(settings)
            #expect(await eventually { await discord.attempts.count == 2 })
            #expect(await stays(for: .milliseconds(100)) { await discord.attempts.count == 2 })
            #expect(await discord.connectAttempts == [validClientID, "987654321098765432"])
        }
    }

    @Test func invalidClientIDIsRetriedAfterTheRetryDelay() async throws {
        let discord = FakeDiscord()
        await discord.failConnects(with: .invalidClientID)
        try await withController(discord: discord, configure: { $0.invalidClientIDRetry = .milliseconds(150) }) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await discord.connectAttempts.count >= 3 })
            let times = await discord.connectTimes
            for (earlier, later) in zip(times, times.dropFirst()) {
                #expect(later - earlier >= .milliseconds(150))
            }
        }
    }

    @Test func discordNotRunningIsRetriedEveryTick() async throws {
        let discord = FakeDiscord()
        await discord.failConnects(with: .discordNotRunning)
        try await withController(discord: discord) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await discord.connectAttempts.count >= 5 })
            #expect(await h.controller.snapshot.discord == .unavailable(.discordNotRunning))
            #expect(await h.controller.snapshot.vita == .connected)
            #expect(await discord.attempts.isEmpty)

            await discord.failConnects(with: nil)
            #expect(await eventually { await h.controller.snapshot.publishedActivity?.details == persona.name })
            #expect(await h.controller.snapshot.discord == .connected(testUser))
        }
    }

    @Test func clientIDChangeReconnectsImmediately() async throws {
        try await withController(configure: { $0.pollIntervalOverride = .seconds(30) }) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.publishedActivity != nil })

            var settings = PresenceSettings.valid
            settings.clientID = " 987654321098765432 "
            await h.controller.updateSettings(settings)
            #expect(await eventually(timeout: .seconds(1)) {
                await h.discord.connectAttempts == [validClientID, "987654321098765432"]
            })
            #expect(await h.discord.disconnects == 1)
            #expect(await eventually { await h.discord.acceptedActivities.count == 2 })
            #expect(await h.controller.snapshot.discord == .connected(testUser))
        }
    }

    @Test func clientIDChangeAbandonsAConnectInProgress() async throws {
        let discord = FakeDiscord()
        await discord.setConnectHangs(true)
        try await withController(discord: discord) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await discord.connectAttempts.count == 1 })

            await discord.setConnectHangs(false)
            var settings = PresenceSettings.valid
            settings.clientID = "987654321098765432"
            await h.controller.updateSettings(settings)
            #expect(await eventually { await h.controller.snapshot.discord == .connected(testUser) })
            #expect(await discord.connectAttempts == [validClientID, "987654321098765432"])
        }
    }

    @Test func rateLimitCoalescesABurstAndSendsTheNewest() async throws {
        let games = (1...6).map { VitaTitle(index: 1, titleID: "PCSE0000\($0)", name: "Game \($0)") }
        let fetcher = FakeFetcher(steps: games.map { .title($0) })
        try await withController(fetcher, configure: {
            $0.activityBurst = 2
            $0.activityWindow = .milliseconds(600)
        }) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.discord.acceptedActivities.last??.details == "Game 6" })
            #expect(await stays(for: .milliseconds(100)) { await h.discord.accepted.count == 3 })

            let sent = await h.discord.accepted
            #expect(sent.map { $0.activity?.details } == ["Game 1", "Game 2", "Game 6"])
            for (earlier, later) in zip(sent, sent.dropFirst(2)) {
                #expect(later.at - earlier.at >= .milliseconds(590), "at most activityBurst sends per activityWindow")
            }
        }
    }

    // MARK: Settings changes

    @Test func addressChangeResetsStateAndPollsImmediately() async throws {
        let fetcher = FakeFetcher(.title(persona))
        try await withController(fetcher, configure: { $0.pollIntervalOverride = .seconds(30) }) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.publishedActivity != nil })
            await fetcher.setStep(.failure(.refused), forHost: "192.168.1.20")
            await h.controller.pollNow()
            #expect(await eventually { await h.controller.snapshot.vita == .failing(.refused, failures: 1) })

            await fetcher.setStep(.failure(.timedOut), forHost: "192.168.1.21")
            var settings = PresenceSettings.valid
            settings.address = "192.168.1.21"
            await h.controller.updateSettings(settings)
            #expect(await eventually(timeout: .seconds(1)) {
                await fetcher.calls.contains { $0.host == "192.168.1.21" }
            })
            #expect(await eventually { await h.controller.snapshot.vita == .failing(.timedOut, failures: 1) })
            let snapshot = await h.controller.snapshot
            #expect(snapshot.title == nil)
            #expect(snapshot.sessionStart == nil)
            #expect(snapshot.lastSuccess == nil)
            #expect(snapshot.host == "192.168.1.21")
            #expect(await eventually { await h.discord.acceptedActivities.last == .some(nil) })
        }
    }

    @Test func addressChangeStartsANewSessionForTheSameGame() async throws {
        try await withController(configure: { $0.pollIntervalOverride = .seconds(30) }) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.publishedActivity != nil })
            let start = try #require(await h.controller.snapshot.sessionStart)

            try await Task.sleep(for: .milliseconds(5))
            var settings = PresenceSettings.valid
            settings.address = "192.168.1.21"
            await h.controller.updateSettings(settings)
            #expect(await eventually { await h.controller.snapshot.host == "192.168.1.21" })
            #expect(await eventually { await h.controller.snapshot.title == persona })
            let newStart = try #require(await h.controller.snapshot.sessionStart)
            #expect(newStart > start)
        }
    }

    @Test func addressChangeInvalidatesTheOldMACAddress() async throws {
        let resolver = FakeResolver()
        var settings = PresenceSettings.valid
        settings.address = "a4:5e:60:01:02:03"
        let oldAddress = try #require(settings.vitaAddress)
        try await withController(resolver: resolver) { h in
            await h.controller.start(with: settings)
            #expect(await eventually { await h.controller.snapshot.publishedActivity != nil })
            #expect(await resolver.invalidated.isEmpty)

            settings.address = "a4:5e:60:0a:0b:0c"
            await h.controller.updateSettings(settings)
            #expect(await eventually { await resolver.invalidated == [oldAddress] })
            let newAddress = try #require(settings.vitaAddress)
            #expect(await eventually { await resolver.resolved.last == newAddress })
        }
    }

    @Test func pollIntervalChangeTakesEffectAtOnce() async throws {
        var settings = PresenceSettings.valid
        settings.pollInterval = 300
        try await withController(configure: { $0.pollIntervalOverride = nil }) { h in
            await h.controller.start(with: settings)
            #expect(await eventually { await h.fetcher.callCount == 1 })
            #expect(await stays(for: .milliseconds(50)) { await h.fetcher.callCount == 1 })

            settings.pollInterval = 3
            await h.controller.updateSettings(settings)
            #expect(await eventually(timeout: .seconds(1)) { await h.fetcher.callCount == 2 })
        }
    }

    @Test func pollStartedBeforeAnAddressChangeIsDiscarded() async throws {
        let fetcher = FakeFetcher(.title(persona))
        await fetcher.setStep(.late(.title(persona), after: .milliseconds(250)), forHost: "192.168.1.20")
        await fetcher.setStep(.title(gravityRush), forHost: "192.168.1.21")
        try await withController(fetcher, configure: { $0.pollIntervalOverride = .seconds(30) }) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await fetcher.callCount == 1 })

            var settings = PresenceSettings.valid
            settings.address = "192.168.1.21"
            await h.controller.updateSettings(settings)
            #expect(await eventually { await h.controller.snapshot.title == gravityRush })
            // The first poll's result arrives late and must not win.
            #expect(await stays(for: .milliseconds(400)) { await h.controller.snapshot.title == gravityRush })
            #expect(await h.discord.attempts.allSatisfy { $0?.details != persona.name })
        }
    }

    @Test func pollInFlightIsCancelledByAnAddressChange() async throws {
        let fetcher = FakeFetcher(.title(gravityRush))
        await fetcher.setStep(.hang, forHost: "192.168.1.20")
        try await withController(fetcher) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await fetcher.callCount == 1 })
            var settings = PresenceSettings.valid
            settings.address = "192.168.1.21"
            await h.controller.updateSettings(settings)
            #expect(await eventually { await fetcher.cancelledCalls == 1 })
            #expect(await eventually { await h.controller.snapshot.title == gravityRush })
        }
    }

    @Test func addressChangeKeepsADiscordConnectInProgress() async throws {
        let discord = FakeDiscord()
        await discord.setConnectDuration(.milliseconds(300))
        try await withController(discord: discord) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await discord.connectAttempts.count == 1 })

            var settings = PresenceSettings.valid
            settings.address = "192.168.1.21"
            await h.controller.updateSettings(settings)
            #expect(await eventually { await h.controller.snapshot.publishedActivity != nil })
            #expect(await discord.connectAttempts.count == 1, "the new loop waited for the same connect")
            #expect(await h.fetcher.calls.allSatisfy { $0.host == "192.168.1.21" })
        }
    }

    @Test func presentationChangeIsDebouncedIntoOneResync() async throws {
        try await withController(configure: { $0.settingsDebounce = .milliseconds(150) }) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.publishedActivity != nil })

            var settings = PresenceSettings.valid
            let changed = ContinuousClock.now
            for text in ["P", "Pl", "Pla", "Play"] {
                settings.stateText = text
                await h.controller.updateSettings(settings)
            }
            #expect(await eventually { await h.discord.accepted.count == 2 })
            #expect(await stays(for: .milliseconds(150)) { await h.discord.accepted.count == 2 })

            let resync = try #require(await h.discord.accepted.last)
            #expect(resync.activity?.state == "Play")
            #expect(resync.activity?.details == persona.name)
            #expect(resync.at >= changed + .milliseconds(150))
            #expect(await h.discord.connectAttempts.count == 1)
            #expect(await h.controller.snapshot.publishedActivity?.state == "Play")
        }
    }

    @Test func togglingLiveAreaOffClearsAfterTheDebounce() async throws {
        try await withController(FakeFetcher(.title(.liveArea))) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.publishedActivity?.details == "In the LiveArea" })

            var settings = PresenceSettings.valid
            settings.showLiveArea = false
            await h.controller.updateSettings(settings)
            #expect(await eventually { await h.discord.acceptedActivities.last == .some(nil) })
            #expect(await h.controller.snapshot.publishedActivity == nil)
            #expect(await h.controller.snapshot.title == .liveArea)
        }
    }

    @Test func misconfiguredSettingsDontPollUntilFixed() async throws {
        try await withController { h in
            await h.controller.start(with: PresenceSettings())
            let snapshot = await h.controller.snapshot
            #expect(snapshot.isRunning)
            #expect(snapshot.vita == .misconfigured("Enter your Vita's IP or MAC address"))
            #expect(snapshot.discord == .idle)
            #expect(await stays(for: .milliseconds(150)) { await h.fetcher.callCount == 0 })
            await h.controller.pollNow()
            #expect(await stays(for: .milliseconds(50)) { await h.fetcher.callCount == 0 })
            #expect(await h.discord.connectAttempts.isEmpty)

            await h.controller.updateSettings(.valid)
            #expect(await eventually { await h.controller.snapshot.publishedActivity?.details == persona.name })
            #expect(await h.controller.snapshot.vita == .connected)
        }
    }

    @Test func becomingMisconfiguredStopsPollingAndDisconnects() async throws {
        try await withController { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.publishedActivity != nil })

            var settings = PresenceSettings.valid
            settings.clientID = "1234"
            await h.controller.updateSettings(settings)
            let snapshot = await h.controller.snapshot
            #expect(snapshot.isRunning)
            #expect(snapshot.vita == .misconfigured("The application ID should be 16 to 25 digits"))
            #expect(snapshot.discord == .idle)
            #expect(snapshot.title == nil)
            #expect(snapshot.publishedActivity == nil)
            #expect(await eventually { await h.discord.disconnects == 1 })
            #expect(await h.discord.attempts.count == 1, "disconnect() clears the activity, so nothing else is sent")
            let polls = await h.fetcher.callCount
            #expect(await stays(for: .milliseconds(100)) { await h.fetcher.callCount == polls })
        }
    }

    @Test func startWhileRunningBehavesLikeUpdateSettings() async throws {
        try await withController(configure: { $0.pollIntervalOverride = .seconds(30) }) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.fetcher.callCount == 1 })
            var settings = PresenceSettings.valid
            settings.address = "192.168.1.30"
            await h.controller.start(with: settings)
            #expect(await eventually { await h.fetcher.calls.last?.host == "192.168.1.30" })
            #expect(await h.discord.connectAttempts.count == 1)
        }
    }

    @Test func updateSettingsWhileStoppedOnlyStoresThem() async throws {
        try await withController { h in
            await h.controller.updateSettings(.valid)
            await h.controller.pollNow()
            #expect(await stays(for: .milliseconds(80)) { await h.fetcher.callCount == 0 })
            #expect(await h.controller.snapshot == .idle)
        }
    }

    // MARK: Responsiveness

    @Test func pollNowInterruptsALongSleep() async throws {
        try await withController(configure: { $0.pollIntervalOverride = .seconds(30) }) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.vita == .connected })
            try await Task.sleep(for: .milliseconds(30))
            await h.controller.pollNow()
            #expect(await eventually(timeout: .seconds(1)) { await h.fetcher.callCount == 2 })
        }
    }

    @Test func pollNowDuringAPollPollsAgainRightAfterIt() async throws {
        let fetcher = FakeFetcher(.title(persona))
        await fetcher.pause(atCall: 1)
        try await withController(fetcher, configure: { $0.pollIntervalOverride = .seconds(30) }) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await fetcher.callCount == 1 })

            await h.controller.pollNow()
            await fetcher.resume()
            #expect(await eventually(timeout: .seconds(1)) { await fetcher.callCount == 2 })
        }
    }

    @Test func stopDisconnectsPromptlyWhileAFetchHangs() async throws {
        let fetcher = FakeFetcher(.title(persona), .hang)
        try await withController(fetcher) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await fetcher.callCount == 2 })
            #expect(await h.controller.snapshot.publishedActivity != nil)

            let began = ContinuousClock.now
            await h.controller.stop()
            #expect(ContinuousClock.now - began < .seconds(1))
            #expect(await h.controller.snapshot == .idle)
            #expect(await h.discord.disconnects == 1)
            #expect(await h.discord.attempts.count == 1, "disconnect() clears the activity, so nothing else is sent")
            #expect(await !h.discord.isConnected)
            #expect(await eventually { await fetcher.cancelledCalls == 1 })
            #expect(await stays(for: .milliseconds(100)) { await fetcher.callCount == 2 })
        }
    }

    @Test func stopIsPromptWhileDiscordConnectHangs() async throws {
        let discord = FakeDiscord()
        await discord.setConnectHangs(true)
        try await withController(discord: discord) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await discord.connectAttempts.count == 1 })
            let began = ContinuousClock.now
            await h.controller.stop()
            #expect(ContinuousClock.now - began < .seconds(1))
            #expect(await h.controller.snapshot == .idle)
            #expect(await eventually { await discord.disconnects == 1 })
            #expect(await discord.attempts.isEmpty)
        }
    }

    @Test func stopDisconnectsAfterAConnectThatWasInFlight() async throws {
        let discord = FakeDiscord()
        await discord.setConnectDelay(.milliseconds(200))
        try await withController(discord: discord) { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await discord.connectAttempts.count == 1 })
            await h.controller.stop()
            #expect(await eventually { await discord.disconnects == 1 })
            #expect(await stays(for: .milliseconds(300)) { await !discord.isConnected })
        }
    }

    @Test func stopStaysPromptWhenDiscordDoesntAnswer() async throws {
        try await withController { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.publishedActivity != nil })

            await h.discord.setDisconnectDuration(.seconds(3))
            let began = ContinuousClock.now
            await h.controller.stop()
            #expect(ContinuousClock.now - began < .milliseconds(1600))
            #expect(await h.controller.snapshot == .idle)
            #expect(await h.discord.disconnects == 1, "the disconnect was attempted")
        }
    }

    @Test func startAfterStopConnectsAgain() async throws {
        try await withController { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.publishedActivity != nil })
            await h.controller.stop()
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.publishedActivity != nil })
            #expect(await h.discord.connectAttempts.count == 2)
            #expect(await h.discord.disconnects == 1)
            #expect(await h.discord.acceptedActivities.map { $0?.details } == [persona.name, persona.name])
        }
    }

    // MARK: Snapshots

    @Test func snapshotsStreamFollowsTheStateWithoutDuplicates() async throws {
        try await withController { h in
            let collector = SnapshotCollector()
            let consumer = Task {
                for await snapshot in h.controller.snapshots { await collector.append(snapshot) }
            }
            #expect(await eventually { await collector.all.first == .idle })

            await h.controller.start(with: .valid)
            #expect(await eventually { await collector.all.last?.publishedActivity?.details == persona.name })
            #expect(await collector.all.contains { $0.isRunning && $0.discord == .connected(testUser) })
            // Later ticks change nothing but the time of the last answer, and must not repeat a snapshot.
            #expect(await eventually { await h.fetcher.callCount >= 8 })

            await h.controller.stop()
            #expect(await eventually { await collector.all.last == .idle })
            #expect(await stays(for: .milliseconds(100)) { await collector.all.last == .idle })
            consumer.cancel()

            let all = await collector.all
            #expect(zip(all, all.dropFirst()).allSatisfy { $0 != $1 })
        }
    }

    @Test func newIteratorGetsTheCurrentState() async throws {
        try await withController { h in
            await h.controller.start(with: .valid)
            #expect(await eventually { await h.controller.snapshot.publishedActivity != nil })
            try await Task.sleep(for: .milliseconds(50))

            var iterator = h.controller.snapshots.makeAsyncIterator()
            let first = try #require(await iterator.next())
            #expect(first.isRunning)
            #expect(first.title == persona)
        }
    }
}

import Testing
@testable import PresenceKit

@Suite struct TokenBucketTests {
    private let start = ContinuousClock.now

    private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
        start + .milliseconds(milliseconds)
    }

    @Test func startsFullAndAllowsABurst() {
        var bucket = TokenBucket(capacity: 3, refillInterval: .seconds(1), now: start)
        #expect(bucket.consume(now: start) == nil)
        #expect(bucket.consume(now: start) == nil)
        #expect(bucket.consume(now: start) == nil)
        #expect(bucket.consume(now: start) == .seconds(1))
    }

    @Test func waitShrinksUntilTheNextToken() {
        var bucket = TokenBucket(capacity: 2, refillInterval: .seconds(1), now: start)
        #expect(bucket.consume(now: at(0)) == nil)
        #expect(bucket.consume(now: at(100)) == nil)
        #expect(bucket.consume(now: at(200)) == .milliseconds(800))
        #expect(bucket.consume(now: at(750)) == .milliseconds(250))
        #expect(bucket.consume(now: at(1000)) == nil)
        #expect(bucket.consume(now: at(1000)) == .seconds(1))
        #expect(bucket.consume(now: at(1999)) == .milliseconds(1))
        #expect(bucket.consume(now: at(2000)) == nil)
    }

    @Test func waitingDoesNotTakeATokenOrResetTheRefill() {
        var bucket = TokenBucket(capacity: 1, refillInterval: .seconds(1), now: start)
        #expect(bucket.consume(now: at(0)) == nil)
        for elapsed in stride(from: 100, to: 1000, by: 100) {
            #expect(bucket.consume(now: at(elapsed)) == .milliseconds(1000 - elapsed))
        }
        #expect(bucket.consume(now: at(1000)) == nil)
    }

    @Test func refillsOneTokenPerIntervalUpToCapacity() {
        var bucket = TokenBucket(capacity: 3, refillInterval: .seconds(1), now: start)
        for _ in 0..<3 { #expect(bucket.consume(now: at(0)) == nil) }
        // 2.5 intervals later: two tokens earned, the third is half-way.
        #expect(bucket.consume(now: at(2500)) == nil)
        #expect(bucket.consume(now: at(2500)) == nil)
        #expect(bucket.consume(now: at(2500)) == .milliseconds(500))
        // A long idle period refills to capacity and no further.
        for _ in 0..<3 { #expect(bucket.consume(now: at(60_000)) == nil) }
        #expect(bucket.consume(now: at(60_000)) == .seconds(1))
    }

    @Test func aFullBucketStartsCountingAtTheFirstTake() {
        var bucket = TokenBucket(capacity: 2, refillInterval: .seconds(1), now: start)
        // Idle while full: nothing is banked beyond capacity.
        #expect(bucket.consume(now: at(5000)) == nil)
        #expect(bucket.consume(now: at(5000)) == nil)
        #expect(bucket.consume(now: at(5400)) == .milliseconds(600))
    }

    @Test func neverMoreThanCapacityInAnyWindow() {
        // Taking greedily whenever allowed: any `refillInterval` window holds at most `capacity` takes.
        var bucket = TokenBucket(capacity: 5, refillInterval: .seconds(20), now: start)
        var taken: [Int] = []
        for millisecond in stride(from: 0, through: 120_000, by: 250) where bucket.consume(now: at(millisecond)) == nil {
            taken.append(millisecond)
        }
        #expect(taken.count == 5 + 6)
        for (earlier, later) in zip(taken, taken.dropFirst(5)) {
            #expect(later - earlier >= 20_000)
        }
    }

    @Test func capacityIsAtLeastOne() {
        var bucket = TokenBucket(capacity: 0, refillInterval: .seconds(1), now: start)
        #expect(bucket.capacity == 1)
        #expect(bucket.consume(now: start) == nil)
        #expect(bucket.consume(now: start) == .seconds(1))
    }

    @Test func nonPositiveIntervalNeverLimits() {
        var bucket = TokenBucket(capacity: 1, refillInterval: .zero, now: start)
        for _ in 0..<10 { #expect(bucket.consume(now: start) == nil) }
    }
}

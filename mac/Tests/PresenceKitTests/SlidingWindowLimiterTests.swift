import Testing
@testable import PresenceKit

@Suite struct SlidingWindowLimiterTests {
    @Test func allowsExactlyTheLimitInsideTheWindow() {
        let start = ContinuousClock.now
        var limiter = SlidingWindowLimiter(limit: 5, window: .seconds(20))
        for _ in 0..<5 {
            #expect(limiter.consume(now: start) == nil)
        }
        #expect(limiter.consume(now: start) == .seconds(20))
        #expect(limiter.consume(now: start + .seconds(19)) == .seconds(1))
        #expect(limiter.consume(now: start + .seconds(20)) == nil)
    }

    @Test func aSpreadOfSendsFreesTheOldestFirst() {
        let start = ContinuousClock.now
        var limiter = SlidingWindowLimiter(limit: 2, window: .seconds(10))
        #expect(limiter.consume(now: start) == nil)
        #expect(limiter.consume(now: start + .seconds(4)) == nil)
        #expect(limiter.consume(now: start + .seconds(9)) == .seconds(1))
        #expect(limiter.consume(now: start + .seconds(10)) == nil)
    }

    @Test func aNonPositiveWindowNeverLimits() {
        var limiter = SlidingWindowLimiter(limit: 1, window: .zero)
        #expect(limiter.consume(now: .now) == nil)
        #expect(limiter.consume(now: .now) == nil)
    }
}

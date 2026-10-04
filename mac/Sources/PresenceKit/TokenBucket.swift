/// A token bucket that enforces Discord's documented activity rate limit (5 updates per 20 seconds) while
/// still allowing short bursts.
public struct TokenBucket: Sendable {
    public let capacity: Int
    public let refillInterval: Duration

    private var tokens: Int
    /// Where the next token's `refillInterval` is counted from. Only meaningful while the bucket isn't full:
    /// a full bucket earns nothing, so the count starts when the first token of a full bucket is taken.
    private var refillStart: ContinuousClock.Instant

    /// A full bucket. One token is added every `refillInterval`, up to `capacity` (at least 1).
    /// A non-positive `refillInterval` never limits.
    public init(capacity: Int, refillInterval: Duration, now: ContinuousClock.Instant) {
        self.capacity = max(capacity, 1)
        self.refillInterval = refillInterval
        tokens = self.capacity
        refillStart = now
    }

    /// Takes a token if one is available and returns `nil`. Otherwise returns how long to wait until a token
    /// becomes available (and takes nothing).
    public mutating func consume(now: ContinuousClock.Instant) -> Duration? {
        guard refillInterval > .zero else { return nil }
        refill(now: now)
        guard tokens > 0 else { return refillStart + refillInterval - now }
        if tokens == capacity { refillStart = now }
        tokens -= 1
        return nil
    }

    private mutating func refill(now: ContinuousClock.Instant) {
        guard tokens < capacity, now > refillStart else { return }
        // Capped before converting, so a tiny interval over a long time can't overflow `Int`.
        let earned = Int(min((now - refillStart) / refillInterval, Double(capacity)))
        guard earned > 0 else { return }
        tokens = min(tokens + earned, capacity)
        refillStart += refillInterval * earned
    }
}

/// Discord's activity rate limit: at most `limit` sends in any window of `window`.
///
/// The next send waits until the oldest send in the window is `window` old. A non-positive `window` never
/// limits. Unlike a token bucket, five sends at once allow another five only after the whole window, not one
/// every `window / limit`.
public struct SlidingWindowLimiter: Sendable {
    public let limit: Int
    public let window: Duration

    /// Send times still inside the window, oldest first.
    private var sentAt: [ContinuousClock.Instant] = []

    public init(limit: Int, window: Duration) {
        self.limit = max(limit, 1)
        self.window = window
    }

    /// Records a send and returns `nil` when one is allowed now. Otherwise returns how long to wait, and
    /// records nothing.
    public mutating func consume(now: ContinuousClock.Instant) -> Duration? {
        guard window > .zero else { return nil }
        sentAt.removeAll { now - $0 >= window }
        if sentAt.count >= limit, let oldest = sentAt.first {
            let wait = oldest + window - now
            return wait > .zero ? wait : .zero
        }
        sentAt.append(now)
        return nil
    }
}

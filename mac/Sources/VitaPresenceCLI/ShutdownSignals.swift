import Darwin
import Dispatch
import os

/// Graceful shutdown on SIGINT and SIGTERM, observed with `DispatchSourceSignal`.
///
/// Creating it replaces the default handlers, which would kill the process without clearing the presence:
/// the first signal ends `wait()`, and a second one exits right away with status 130.
final class ShutdownSignals: Sendable {
    /// Retained so the handlers stay installed.
    private let sources: [any DispatchSourceSignal]
    private let received: AsyncStream<Void>

    init() {
        let (received, continuation) = AsyncStream.makeStream(of: Void.self)
        let count = OSAllocatedUnfairLock(initialState: 0)
        let queue = DispatchQueue(label: "vitapresence-cli.signals")
        self.received = received
        sources = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler {
                if count.withLock({ $0 += 1; return $0 }) == 1 {
                    continuation.yield()
                } else {
                    exit(130)
                }
            }
            source.resume()
            return source
        }
    }

    /// Returns when the first signal arrives, or when the calling task is cancelled.
    func wait() async {
        for await _ in received {
            return
        }
    }
}

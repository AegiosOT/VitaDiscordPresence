import Foundation
import Network
import os

/// What one `receive` on an IPC socket produced. Data comes first: a chunk can carry bytes together with
/// the end of the stream or an error.
struct IPCChunk: Sendable {
    var data: Data
    var isComplete: Bool
    var error: NWError?
}

/// Async wrappers that only bridge Network.framework callbacks; the protocol logic lives in
/// `DiscordIPCClient`.
extension NWConnection {
    /// Starts the connection and waits until it is ready. Returns `false` when it reports `.waiting` (which is
    /// how a missing socket, ENOENT, or one nobody listens on, ECONNREFUSED, show up), `.failed` or
    /// `.cancelled`, when `timeout` passes, or when the task is cancelled. The caller cancels it then.
    func startAndWaitUntilReady(on queue: DispatchQueue, timeout: Duration) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let result = OneShot(continuation)
                guard !Task.isCancelled else { return result.resume(returning: false) }
                stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        result.resume(returning: true)
                    case .waiting, .failed, .cancelled:
                        result.resume(returning: false)
                    default:
                        break
                    }
                }
                queue.asyncAfter(deadline: .now() + timeout.timeInterval) { result.resume(returning: false) }
                start(queue: queue)
            }
        } onCancel: {
            cancel()
        }
    }

    /// Waits for the next bytes, the end of the stream, or an error. Network.framework calls the completion
    /// exactly once, also when the connection is cancelled.
    func receiveChunk() async -> IPCChunk {
        await withCheckedContinuation { (continuation: CheckedContinuation<IPCChunk, Never>) in
            receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                continuation.resume(returning: IPCChunk(data: data ?? Data(), isComplete: isComplete, error: error))
            }
        }
    }

    /// Sends `data` in one write and waits until the network stack has processed it, the send failed, or
    /// `timeout` passed.
    func sendAndWait(_ data: Data, queue: DispatchQueue, timeout: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done = OneShot(continuation)
            send(content: data, completion: .contentProcessed { _ in done.resume(returning: ()) })
            queue.asyncAfter(deadline: .now() + timeout.timeInterval) { done.resume(returning: ()) }
        }
    }
}

/// Resumes a continuation once, for whichever callback fires first (state change, completion, timer); later
/// calls do nothing.
final class OneShot<Value: Sendable>: Sendable {
    private let continuation: OSAllocatedUnfairLock<CheckedContinuation<Value, Never>?>

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = OSAllocatedUnfairLock(initialState: continuation)
    }

    func resume(returning value: Value) {
        let continuation = self.continuation.withLock { stored in
            defer { stored = nil }
            return stored
        }
        continuation?.resume(returning: value)
    }
}

extension Duration {
    /// The duration in seconds, for `DispatchTime` arithmetic.
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

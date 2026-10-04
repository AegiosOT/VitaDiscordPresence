import os
@testable import VitaKit

/// A value shared between a test and the fakes it drives.
final class Locked<Value: Sendable>: Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    init(_ value: Value) {
        lock = OSAllocatedUnfairLock(initialState: value)
    }

    var value: Value {
        lock.withLock { $0 }
    }

    func withLock<R: Sendable>(_ body: @Sendable (inout Value) -> R) -> R {
        lock.withLock(body)
    }
}

/// A `VitaTitleFetching` fake that answers from a closure and records how it was called.
final class FakeFetcher: VitaTitleFetching {
    private struct Record {
        var calls: [String] = []
        var inFlight = 0
        var maxInFlight = 0
        var cancellations = 0
    }

    private let answer: @Sendable (String) async throws -> VitaTitle
    private let record = Locked(Record())

    init(_ answer: @escaping @Sendable (String) async throws -> VitaTitle) {
        self.answer = answer
    }

    /// Hosts in the order they were probed.
    var calls: [String] { record.value.calls }
    /// Probes currently running.
    var inFlight: Int { record.value.inFlight }
    /// The most probes that ever ran at the same time.
    var maxInFlight: Int { record.value.maxInFlight }
    /// Probes that ended with `CancellationError`.
    var cancellations: Int { record.value.cancellations }

    func fetchTitle(from host: String) async throws -> VitaTitle {
        record.withLock { state in
            state.calls.append(host)
            state.inFlight += 1
            state.maxInFlight = max(state.maxInFlight, state.inFlight)
        }
        defer { record.withLock { $0.inFlight -= 1 } }
        do {
            return try await answer(host)
        } catch is CancellationError {
            record.withLock { $0.cancellations += 1 }
            throw CancellationError()
        }
    }
}

/// Polls `condition` until it holds or `timeout` passes, and returns whether it held.
func eventually(within timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// A title for fake Vitas.
func fakeTitle(_ name: String) -> VitaTitle {
    VitaTitle(index: 1, titleID: "PCSE00120", name: name)
}

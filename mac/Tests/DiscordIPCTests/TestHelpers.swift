import Foundation
import Testing
@testable import DiscordIPC

/// Polls `condition` until it holds or `timeout` passes, and returns whether it held.
func eventually(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// The error `body` throws, or `nil` when it doesn't throw.
func caughtError(_ body: () async throws -> Void) async -> (any Error)? {
    do {
        try await body()
        return nil
    } catch {
        return error
    }
}

func isProtocolViolation(_ error: (any Error)?) -> Bool {
    if case .protocolViolation? = error as? DiscordIPCError { return true }
    return false
}

/// A JSON payload as a dictionary.
func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// A frame whose payload is `object` serialized as JSON.
func jsonFrame(_ opcode: DiscordOpcode, _ object: [String: Any]) throws -> DiscordFrame {
    DiscordFrame(opcode: opcode, payload: try JSONSerialization.data(withJSONObject: object))
}

/// An 8-byte frame header with arbitrary values.
func frameHeader(opcode: UInt32, length: Int) -> Data {
    var data = Data()
    for value in [opcode, UInt32(length)] {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    return data
}

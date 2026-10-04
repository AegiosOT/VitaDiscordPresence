import Foundation

/// Opcodes of Discord's local IPC protocol.
public enum DiscordOpcode: UInt32, Sendable {
    case handshake = 0
    case frame = 1
    case close = 2
    case ping = 3
    case pong = 4
}

/// One IPC message: an 8-byte header (opcode, then payload length, both uint32 little-endian) followed by
/// a UTF-8 JSON payload.
public struct DiscordFrame: Sendable, Equatable {
    public static let headerLength = 8
    /// Largest payload accepted from Discord; anything bigger is treated as a protocol violation.
    /// Discord's READY is about 400 bytes.
    public static let maximumPayloadLength = 1 << 20

    public var opcode: DiscordOpcode
    public var payload: Data

    public init(opcode: DiscordOpcode, payload: Data) {
        self.opcode = opcode
        self.payload = payload
    }

    /// Encodes `json` with `JSONEncoder` as the payload (keys sorted, slashes unescaped).
    public init(opcode: DiscordOpcode, json: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.init(opcode: opcode, payload: try encoder.encode(json))
    }

    /// Header plus payload, ready to be written in a single write.
    public func encoded() -> Data {
        var data = Data(capacity: Self.headerLength + payload.count)
        data.appendLittleEndian(opcode.rawValue)
        data.appendLittleEndian(UInt32(payload.count))
        data.append(payload)
        return data
    }
}

/// Incremental frame decoder for a byte stream: append bytes as they arrive, then pop complete frames.
public struct DiscordFrameDecoder: Sendable {
    private var buffer = Data()
    private var failure: DiscordIPCError?

    public init() {}

    /// Appends received bytes.
    public mutating func append(_ data: Data) {
        guard failure == nil else { return }
        buffer.append(data)
    }

    /// Removes and returns the next complete frame, or `nil` when more bytes are needed.
    /// - Throws: `DiscordIPCError.protocolViolation` for an unknown opcode or a payload longer than
    ///   `DiscordFrame.maximumPayloadLength`. The decoder is unusable afterwards.
    public mutating func nextFrame() throws(DiscordIPCError) -> DiscordFrame? {
        if let failure { throw failure }
        guard buffer.count >= DiscordFrame.headerLength else { return nil }
        let rawOpcode = word(at: 0)
        let length = Int(word(at: 4))
        guard let opcode = DiscordOpcode(rawValue: rawOpcode) else {
            throw fail("Unknown opcode \(rawOpcode)")
        }
        guard length <= DiscordFrame.maximumPayloadLength else {
            throw fail("Frame payload of \(length) bytes exceeds \(DiscordFrame.maximumPayloadLength) bytes")
        }
        let frameEnd = buffer.startIndex + DiscordFrame.headerLength + length
        guard buffer.endIndex >= frameEnd else { return nil }
        let payload = buffer.subdata(in: (buffer.startIndex + DiscordFrame.headerLength)..<frameEnd)
        buffer.removeSubrange(buffer.startIndex..<frameEnd)
        return DiscordFrame(opcode: opcode, payload: payload)
    }

    private mutating func fail(_ reason: String) -> DiscordIPCError {
        let error = DiscordIPCError.protocolViolation(reason)
        failure = error
        buffer = Data()
        return error
    }

    /// The little-endian uint32 at `offset` bytes into the buffer.
    private func word(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for byte in 0..<4 {
            value |= UInt32(buffer[buffer.startIndex + offset + byte]) << (8 * byte)
        }
        return value
    }
}

extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

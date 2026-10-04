import Foundation
import Testing
@testable import DiscordIPC

@Suite struct DiscordFrameTests {
    @Test func encodesLittleEndianHeaderThenPayload() {
        let frame = DiscordFrame(opcode: .ping, payload: Data([0xAA, 0xBB, 0xCC]))
        #expect(frame.encoded() == Data([3, 0, 0, 0, 3, 0, 0, 0, 0xAA, 0xBB, 0xCC]))
    }

    @Test func handshakeHeaderCarriesTheUTF8ByteCount() {
        // 40 bytes, so the length field is 28 00 00 00.
        let payload = Data(#"{"v":1,"client_id":"383226320970055681"}"#.utf8)
        let bytes = [UInt8](DiscordFrame(opcode: .handshake, payload: payload).encoded())
        #expect(bytes.prefix(8) == [0x00, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00])
        #expect(Data(bytes.dropFirst(8)) == payload)
    }

    @Test func encodesTheClientsHandshakePayload() throws {
        let frame = try DiscordFrame(opcode: .handshake, json: HandshakePayload(clientID: "383226320970055681"))
        #expect(String(decoding: frame.payload, as: UTF8.self) == #"{"client_id":"383226320970055681","v":1}"#)
        #expect([UInt8](frame.encoded().prefix(8)) == [0x00, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00])
    }

    @Test func encodesJSONWithSortedKeysAndUnescapedSlashes() throws {
        let frame = try DiscordFrame(opcode: .frame, json: ["url": "https://example.com/a.png", "a": "b"])
        #expect(frame.opcode == .frame)
        #expect(String(decoding: frame.payload, as: UTF8.self) == #"{"a":"b","url":"https://example.com/a.png"}"#)
    }

    @Test func decodesWhatItEncodes() throws {
        let frames = [
            DiscordFrame(opcode: .handshake, payload: Data(#"{"v":1}"#.utf8)),
            DiscordFrame(opcode: .frame, payload: Data(#"{"cmd":"SET_ACTIVITY"}"#.utf8)),
            DiscordFrame(opcode: .close, payload: Data("{}".utf8)),
            DiscordFrame(opcode: .ping, payload: Data()),
            DiscordFrame(opcode: .pong, payload: Data([0, 1, 2])),
        ]
        for frame in frames {
            var decoder = DiscordFrameDecoder()
            decoder.append(frame.encoded())
            let decoded = try decoder.nextFrame()
            #expect(decoded == frame)
            let rest = try decoder.nextFrame()
            #expect(rest == nil)
        }
    }

    @Test func decodesByteByByte() throws {
        let frame = DiscordFrame(opcode: .frame, payload: Data(#"{"cmd":"DISPATCH","evt":"READY"}"#.utf8))
        let bytes = frame.encoded()
        var decoder = DiscordFrameDecoder()
        var decoded: [DiscordFrame] = []
        for (index, byte) in bytes.enumerated() {
            decoder.append(Data([byte]))
            if let next = try decoder.nextFrame() {
                #expect(index == bytes.count - 1)
                decoded.append(next)
            }
        }
        #expect(decoded == [frame])
    }

    @Test func decodesSeveralFramesFromOneAppendAndKeepsTheRest() throws {
        let first = DiscordFrame(opcode: .frame, payload: Data(#"{"n":1}"#.utf8))
        let second = DiscordFrame(opcode: .ping, payload: Data(#"{"n":2}"#.utf8))
        let third = DiscordFrame(opcode: .close, payload: Data(#"{"n":3}"#.utf8))
        let thirdBytes = third.encoded()
        var decoder = DiscordFrameDecoder()

        decoder.append(first.encoded() + second.encoded() + thirdBytes.prefix(5))
        var decoded: [DiscordFrame?] = []
        for _ in 0..<3 { decoded.append(try decoder.nextFrame()) }
        #expect(decoded == [first, second, nil])

        decoder.append(thirdBytes.dropFirst(5))
        let last = try decoder.nextFrame()
        #expect(last == third)
        let rest = try decoder.nextFrame()
        #expect(rest == nil)
    }

    @Test func decodesAnEmptyPayload() throws {
        var decoder = DiscordFrameDecoder()
        decoder.append(frameHeader(opcode: 4, length: 0))
        let decoded = try decoder.nextFrame()
        #expect(decoded == DiscordFrame(opcode: .pong, payload: Data()))
    }

    @Test func acceptsThePayloadLimit() throws {
        let frame = DiscordFrame(opcode: .frame, payload: Data(count: DiscordFrame.maximumPayloadLength))
        var decoder = DiscordFrameDecoder()
        decoder.append(frame.encoded())
        let decoded = try #require(try decoder.nextFrame())
        #expect(decoded.opcode == .frame)
        #expect(decoded.payload.count == DiscordFrame.maximumPayloadLength)
    }

    @Test func rejectsAnOversizedPayloadFromTheHeaderAlone() {
        var decoder = DiscordFrameDecoder()
        decoder.append(frameHeader(opcode: 1, length: DiscordFrame.maximumPayloadLength + 1))
        let error = decoderError(&decoder)
        #expect(isProtocolViolation(error))
    }

    @Test(arguments: [UInt32(5), 99, .max])
    func rejectsUnknownOpcodes(opcode: UInt32) {
        var decoder = DiscordFrameDecoder()
        decoder.append(frameHeader(opcode: opcode, length: 2) + Data("{}".utf8))
        let error = decoderError(&decoder)
        #expect(isProtocolViolation(error))
    }

    @Test func staysFailedAfterAnError() {
        var decoder = DiscordFrameDecoder()
        decoder.append(frameHeader(opcode: 9, length: 0))
        #expect(isProtocolViolation(decoderError(&decoder)))
        decoder.append(DiscordFrame(opcode: .ping, payload: Data()).encoded())
        #expect(isProtocolViolation(decoderError(&decoder)))
    }

    /// The error `nextFrame()` throws, or `nil`.
    private func decoderError(_ decoder: inout DiscordFrameDecoder) -> DiscordIPCError? {
        do {
            _ = try decoder.nextFrame()
            return nil
        } catch {
            return error
        }
    }
}

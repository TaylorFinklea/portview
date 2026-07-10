// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import PortviewProtocol

@Suite struct FrameTests {
    @Test func encodeThenDecodeYieldsSameMessage() throws {
        let hello = ClientHello(protocolVersion: 1, deviceID: "D", deviceName: "N", codecs: [.hevc])
        let frame = Frame.encode(hello)
        let decoded = try Frame.decode(frame)
        #expect(decoded == .clientHello(hello))
    }

    @Test func frameBodyLengthCountsTypeBytePlusPayload() throws {
        let bye = Bye(reason: "x")            // payload: putString("x") => varint 1 + 1 byte = 2 bytes
        let frame = Frame.encode(bye)
        // frame = [bodyLen varint][type][payload]; bodyLen = 1 (type) + 2 (payload) = 3
        #expect(frame.first == 3)
        var r = BinaryReader(frame)
        #expect(try r.varUInt() == 3)
    }

    @Test func decodingUnknownTypeThrows() {
        // bodyLen=1, type=99 (unknown), no payload
        let bytes: [UInt8] = [0x01, 99]
        #expect(throws: WireError.unknownMessageType(99)) {
            _ = try Frame.decode(bytes)
        }
    }

    @Test func decodeRejectsBodyLengthAboveIntMax() {
        // varint for 2^63 (> Int.max): Int(bodyLength) must never see this value.
        let bytes: [UInt8] = [0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01]
        #expect(throws: WireError.malformed("frame length exceeds maximum")) {
            _ = try Frame.decode(bytes)
        }
    }

    @Test func decodeRejectsBodyLengthOverCeiling() {
        var w = BinaryWriter()
        w.putVarUInt(Frame.maxBodyLength + 1)
        #expect(throws: WireError.malformed("frame length exceeds maximum")) {
            _ = try Frame.decode(w.bytes)
        }
    }

    @Test func anyMessageReportsItsType() {
        #expect(AnyMessage.bye(Bye(reason: "")).messageType == .bye)
        #expect(AnyMessage.videoFrame(VideoFrame(sequence: 0, ptsMicros: 0, isKeyframe: false, displayID: 0, width: 0, height: 0, data: [])).messageType == .videoFrame)
    }
}

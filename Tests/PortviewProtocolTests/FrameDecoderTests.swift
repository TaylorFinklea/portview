import Testing
@testable import PortviewProtocol

@Suite struct FrameDecoderTests {
    @Test func decodesTwoMessagesFromOneChunk() throws {
        let a = Bye(reason: "first")
        let b = Bye(reason: "second")
        var stream = Frame.encode(a)
        stream.append(contentsOf: Frame.encode(b))

        var decoder = FrameDecoder()
        let messages = try decoder.push(stream)
        #expect(messages == [.bye(a), .bye(b)])
    }

    @Test func buffersPartialFrameUntilComplete() throws {
        let m = ClientHello(protocolVersion: 1, deviceID: "DEVICE", deviceName: "Phone", codecs: [.hevc, .h264])
        let frame = Frame.encode(m)
        let split = frame.count / 2

        var decoder = FrameDecoder()
        #expect(try decoder.push(Array(frame[0..<split])).isEmpty)   // not enough yet
        let messages = try decoder.push(Array(frame[split...]))      // now complete
        #expect(messages == [.clientHello(m)])
    }

    @Test func handlesByteAtATimeDelivery() throws {
        let m = Bye(reason: "trickle")
        let frame = Frame.encode(m)
        var decoder = FrameDecoder()
        var collected: [AnyMessage] = []
        for byte in frame {
            collected.append(contentsOf: try decoder.push([byte]))
        }
        #expect(collected == [.bye(m)])
    }

    @Test func rejectsFrameLengthAboveIntMax() {
        // varint for 2^63 (> Int.max): nine continuation bytes then 0x01.
        // Int(bodyLength) must never see this value — it would trap uncatchably.
        let header: [UInt8] = [0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01]
        var decoder = FrameDecoder()
        #expect(throws: WireError.malformed("frame length exceeds maximum")) {
            _ = try decoder.push(header)
        }
    }

    @Test func rejectsFrameLengthJustOverCeiling() {
        var w = BinaryWriter()
        w.putVarUInt(Frame.maxBodyLength + 1)
        var decoder = FrameDecoder()
        #expect(throws: WireError.malformed("frame length exceeds maximum")) {
            _ = try decoder.push(w.bytes)
        }
    }

    @Test func skipsUnknownTagWithoutWedging() throws {
        let a = Bye(reason: "first")
        let b = Bye(reason: "second")

        // unknown-tag frame: bodyLen=1, type=99 (unknown), no payload
        let unknownFrame: [UInt8] = [0x01, 99]

        var stream = Frame.encode(a)
        stream.append(contentsOf: unknownFrame)
        stream.append(contentsOf: Frame.encode(b))

        var decoder = FrameDecoder()
        let messages = try decoder.push(stream)
        #expect(messages == [.bye(a), .bye(b)])

        let c = Bye(reason: "third")
        let more = try decoder.push(Frame.encode(c))
        #expect(more == [.bye(c)])
    }
}

import Testing
@testable import PortholeProtocol

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
}

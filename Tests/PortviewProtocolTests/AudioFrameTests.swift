import Testing
@testable import PortviewProtocol

@Suite struct AudioFrameTests {
    @Test func audioFrameRoundTrips() throws {
        let message = AudioFrame(sampleRate: 48_000, channels: 2, ptsMicros: 123_456,
                                 data: [0, 1, 2, 3, 250, 255])
        var w = BinaryWriter()
        message.encode(into: &w)
        var r = BinaryReader(w.bytes)
        #expect(try AudioFrame(from: &r) == message)
        #expect(AudioFrame.messageType == .audioFrame)
    }

    @Test func audioFrameThroughFrame() throws {
        let any: AnyMessage = .audioFrame(AudioFrame(sampleRate: 44_100, channels: 1, ptsMicros: 0, data: [9, 9]))
        #expect(try Frame.decode(Frame.encodeAny(any)) == any)
    }
}

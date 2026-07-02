import Testing
@testable import PortviewProtocol

/// Client → host request for an immediate keyframe, used to recover the delta chain after a gap
/// (returning from background, or a decoder reset). Empty payload — the host forces a keyframe on the
/// connection's active capture.
@Suite struct RequestKeyframeTests {
    @Test func requestKeyframeRoundTrips() throws {
        let message = RequestKeyframe()

        var writer = BinaryWriter()
        message.encode(into: &writer)
        #expect(writer.bytes.isEmpty)

        var reader = BinaryReader(writer.bytes)
        let decoded = try RequestKeyframe(from: &reader)
        #expect(decoded == message)
        #expect(RequestKeyframe.messageType == .requestKeyframe)
    }

    @Test func requestKeyframeThroughFrame() throws {
        let message = RequestKeyframe()
        #expect(try Frame.decode(Frame.encode(message)) == .requestKeyframe(message))
    }
}

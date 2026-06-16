import Testing
@testable import PortviewProtocol

private func roundTrip<M: WireMessage>(_ message: M) throws -> M {
    var w = BinaryWriter()
    message.encode(into: &w)
    var r = BinaryReader(w.bytes)
    return try M(from: &r)
}

@Suite struct SessionMessageTests {
    @Test func startSessionRoundTrips() throws {
        let m = StartSession(
            displayID: 2, codec: .hevc,
            maxWidth: 2560, maxHeight: 1440, maxFPS: 60, targetBitrate: 25_000_000
        )
        #expect(try roundTrip(m) == m)
        #expect(StartSession.messageType == .startSession)
    }

    @Test func videoFrameRoundTrips() throws {
        let m = VideoFrame(
            sequence: 42, ptsMicros: 1_000_000, isKeyframe: true,
            displayID: 2, width: 2560, height: 1440, data: [0xDE, 0xAD, 0xBE, 0xEF]
        )
        #expect(try roundTrip(m) == m)
        #expect(VideoFrame.messageType == .videoFrame)
    }

    @Test func emptyVideoFrameDataRoundTrips() throws {
        let m = VideoFrame(sequence: 0, ptsMicros: 0, isKeyframe: false,
                           displayID: 1, width: 100, height: 100, data: [])
        #expect(try roundTrip(m) == m)
    }

    @Test func videoFrameWithViewportRoundTrips() throws {
        let m = VideoFrame(
            sequence: 7, ptsMicros: 500_000, isKeyframe: false,
            displayID: 1, width: 1280, height: 720, data: [0xAB, 0xCD],
            viewportNormalizedX: 0.1, viewportNormalizedY: 0.0,
            viewportNormalizedW: 0.2, viewportNormalizedH: 1.0
        )
        let decoded = try roundTrip(m)
        #expect(decoded == m)
        let epsilon = 1.0 / 65535.0
        #expect(abs(decoded.normalizedViewportX - 0.1) <= epsilon)
        #expect(abs(decoded.normalizedViewportY - 0.0) <= epsilon)
        #expect(abs(decoded.normalizedViewportW - 0.2) <= epsilon)
        #expect(abs(decoded.normalizedViewportH - 1.0) <= epsilon)
    }

    @Test func byeRoundTrips() throws {
        let m = Bye(reason: "user disconnected")
        #expect(try roundTrip(m) == m)
        #expect(Bye.messageType == .bye)
    }

    @Test func protocolErrorRoundTrips() throws {
        let m = ProtocolError(code: 7, message: "no common codec")
        #expect(try roundTrip(m) == m)
        #expect(ProtocolError.messageType == .error)
    }
}

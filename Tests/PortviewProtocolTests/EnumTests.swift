import Testing
@testable import PortviewProtocol

@Suite struct EnumTests {
    @Test func laneRawValuesAreStable() {
        #expect(Lane.control.rawValue == 0)
        #expect(Lane.input.rawValue == 1)
        #expect(Lane.video.rawValue == 2)
        #expect(Lane.audio.rawValue == 3)
        #expect(Lane.clipboard.rawValue == 4)
        #expect(Lane.files.rawValue == 5)
    }

    @Test func codecRawValuesAreStable() {
        #expect(Codec.h264.rawValue == 0)
        #expect(Codec.hevc.rawValue == 1)
    }

    @Test func negotiatePicksTheLowerCommonVersion() {
        #expect(ProtocolVersion.negotiate(local: 1, remote: 1) == 1)
        #expect(ProtocolVersion.negotiate(local: 3, remote: 2) == 2)
        #expect(ProtocolVersion.negotiate(local: 2, remote: 5) == 2)
    }

    @Test func negotiateRejectsVersionsBelowMinimum() {
        #expect(ProtocolVersion.negotiate(local: ProtocolVersion.current, remote: 0) == nil)
    }
}

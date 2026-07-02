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

    /// Pins the exact SET of (case, rawValue) pairs in `MessageType.allCases`. Any future
    /// parallel tag addition must update this set explicitly, forcing a visible diff / merge
    /// conflict instead of silently colliding raw values. Complements `GoldenFrameTests`, which
    /// pins per-type wire bytes; this test pins the enum's membership, not its byte encoding.
    @Test func messageTypeAllCasesMatchesExpectedSet() {
        let expected: Set<UInt8> = [
            MessageType.clientHello.rawValue,
            MessageType.serverHello.rawValue,
            MessageType.startSession.rawValue,
            MessageType.videoFrame.rawValue,
            MessageType.bye.rawValue,
            MessageType.error.rawValue,
            MessageType.pointerMove.rawValue,
            MessageType.pointerButton.rawValue,
            MessageType.scroll.rawValue,
            MessageType.typeText.rawValue,
            MessageType.keyEvent.rawValue,
            MessageType.cursorPosition.rawValue,
            MessageType.clipboardUpdate.rawValue,
            MessageType.switchDisplay.rawValue,
            MessageType.fileOffer.rawValue,
            MessageType.fileChunk.rawValue,
            MessageType.audioFrame.rawValue,
            MessageType.viewport.rawValue,
            MessageType.qualityStats.rawValue,
            MessageType.sasClientCommit.rawValue,
            MessageType.sasHostCommit.rawValue,
            MessageType.sasClientReveal.rawValue,
            MessageType.sasHostReveal.rawValue,
            MessageType.sasClientConfirm.rawValue,
            MessageType.displaysUpdate.rawValue,
            MessageType.hostLockStatus.rawValue,
            MessageType.ping.rawValue,
            MessageType.pong.rawValue,
            MessageType.clientFeedback.rawValue,
        ]
        let actual = Set(MessageType.allCases.map(\.rawValue))
        #expect(actual == expected)
        #expect(MessageType.allCases.count == expected.count)
    }
}

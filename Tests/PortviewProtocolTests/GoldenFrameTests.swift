import Testing
@testable import PortviewProtocol

/// Pins the literal on-wire bytes for every `MessageType`. The existing per-message round-trip
/// tests are self-consistent (encode(x) decoded back to x) but blind to a change that shifts the
/// wire format itself, as long as encode/decode drift together. These tests hard-code the actual
/// bytes for one canonical instance per type, so a silent format change is caught even when it's
/// self-consistent. Frame = [varint bodyLen][uint8 messageType][payload].
@Suite struct GoldenFrameTests {
    @Test func messageTypeRawValuesArePinned() {
        #expect(MessageType.clientHello.rawValue == 1)
        #expect(MessageType.serverHello.rawValue == 2)
        #expect(MessageType.startSession.rawValue == 3)
        #expect(MessageType.videoFrame.rawValue == 4)
        #expect(MessageType.bye.rawValue == 5)
        #expect(MessageType.error.rawValue == 6)
        #expect(MessageType.pointerMove.rawValue == 7)
        #expect(MessageType.pointerButton.rawValue == 8)
        #expect(MessageType.scroll.rawValue == 9)
        #expect(MessageType.typeText.rawValue == 10)
        #expect(MessageType.keyEvent.rawValue == 11)
        #expect(MessageType.cursorPosition.rawValue == 12)
        #expect(MessageType.clipboardUpdate.rawValue == 13)
        #expect(MessageType.switchDisplay.rawValue == 14)
        #expect(MessageType.fileOffer.rawValue == 15)
        #expect(MessageType.fileChunk.rawValue == 16)
        #expect(MessageType.audioFrame.rawValue == 17)
        #expect(MessageType.viewport.rawValue == 18)
        #expect(MessageType.qualityStats.rawValue == 19)
        #expect(MessageType.sasClientCommit.rawValue == 20)
        #expect(MessageType.sasHostCommit.rawValue == 21)
        #expect(MessageType.sasClientReveal.rawValue == 22)
        #expect(MessageType.sasHostReveal.rawValue == 23)
        #expect(MessageType.sasClientConfirm.rawValue == 24)
        #expect(MessageType.displaysUpdate.rawValue == 25)
        #expect(MessageType.hostLockStatus.rawValue == 26)
        #expect(MessageType.ping.rawValue == 27)
        #expect(MessageType.pong.rawValue == 28)
        #expect(MessageType.clientFeedback.rawValue == 29)
    }

    @Test func clientHelloWireBytesArePinned() {
        let m = ClientHello(protocolVersion: 1, deviceID: "d1", deviceName: "iPhone", codecs: [.h264, .hevc])
        #expect(Frame.encodeAny(.clientHello(m)) == [16, 1, 0, 1, 2, 100, 49, 6, 105, 80, 104, 111, 110, 101, 2, 0, 1])
    }

    @Test func serverHelloWireBytesArePinned() {
        let m = ServerHello(protocolVersion: 1, displays: [DisplayInfo(id: 1, name: "Main", width: 1920, height: 1080, scaleX100: 200)], chosenCodec: .hevc)
        #expect(Frame.encodeAny(.serverHello(m)) == [24, 2, 0, 1, 1, 0, 0, 0, 1, 4, 77, 97, 105, 110, 0, 0, 7, 128, 0, 0, 4, 56, 0, 200, 1])
    }

    @Test func startSessionWireBytesArePinned() {
        let m = StartSession(displayID: 1, codec: .h264, maxWidth: 1920, maxHeight: 1080, maxFPS: 60, targetBitrate: 8_000_000)
        #expect(Frame.encodeAny(.startSession(m)) == [20, 3, 0, 0, 0, 1, 0, 0, 0, 7, 128, 0, 0, 4, 56, 0, 60, 0, 122, 18, 0])
    }

    @Test func videoFrameWireBytesArePinned() {
        let m = VideoFrame(sequence: 1, ptsMicros: 2, isKeyframe: true, displayID: 1, width: 100, height: 200, data: [1, 2, 3],
                            viewportX: 0, viewportY: 0, viewportW: 65535, viewportH: 65535)
        #expect(Frame.encodeAny(.videoFrame(m)) == [42, 4, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 2, 1, 0, 0, 0, 1, 0, 0, 0, 100, 0, 0, 0, 200, 0, 0, 0, 0, 255, 255, 255, 255, 3, 1, 2, 3])
    }

    @Test func byeWireBytesArePinned() {
        let m = Bye(reason: "done")
        #expect(Frame.encodeAny(.bye(m)) == [6, 5, 4, 100, 111, 110, 101])
    }

    @Test func errorWireBytesArePinned() {
        let m = ProtocolError(code: 42, message: "bad")
        #expect(Frame.encodeAny(.error(m)) == [7, 6, 0, 42, 3, 98, 97, 100])
    }

    @Test func pointerMoveWireBytesArePinned() {
        let m = PointerMove(dx: 5, dy: -5)
        #expect(Frame.encodeAny(.pointerMove(m)) == [9, 7, 0, 0, 0, 5, 255, 255, 255, 251])
    }

    @Test func pointerButtonWireBytesArePinned() {
        let m = PointerButton(button: .left, isDown: true)
        #expect(Frame.encodeAny(.pointerButton(m)) == [3, 8, 0, 1])
    }

    @Test func scrollWireBytesArePinned() {
        let m = Scroll(dx: 1, dy: -1)
        #expect(Frame.encodeAny(.scroll(m)) == [9, 9, 0, 0, 0, 1, 255, 255, 255, 255])
    }

    @Test func typeTextWireBytesArePinned() {
        let m = TypeText(text: "hi")
        #expect(Frame.encodeAny(.typeText(m)) == [4, 10, 2, 104, 105])
    }

    @Test func keyEventWireBytesArePinned() {
        let m = KeyEvent(special: .returnKey, modifiers: [.command, .shift])
        #expect(Frame.encodeAny(.keyEvent(m)) == [4, 11, 3, 0, 0])
    }

    @Test func cursorPositionWireBytesArePinned() {
        let m = CursorPosition(nx: 100, ny: 200)
        #expect(Frame.encodeAny(.cursorPosition(m)) == [5, 12, 0, 100, 0, 200])
    }

    @Test func clipboardUpdateWireBytesArePinned() {
        let m = ClipboardUpdate(text: "hello")
        #expect(Frame.encodeAny(.clipboardUpdate(m)) == [7, 13, 5, 104, 101, 108, 108, 111])
    }

    @Test func switchDisplayWireBytesArePinned() {
        let m = SwitchDisplay(displayID: 7)
        #expect(Frame.encodeAny(.switchDisplay(m)) == [5, 14, 0, 0, 0, 7])
    }

    @Test func fileOfferWireBytesArePinned() {
        let m = FileOffer(transferID: 1, name: "a.txt", size: 10)
        #expect(Frame.encodeAny(.fileOffer(m)) == [19, 15, 0, 0, 0, 1, 5, 97, 46, 116, 120, 116, 0, 0, 0, 0, 0, 0, 0, 10])
    }

    @Test func fileChunkWireBytesArePinned() {
        let m = FileChunk(transferID: 1, isLast: true, data: [9, 8, 7])
        #expect(Frame.encodeAny(.fileChunk(m)) == [10, 16, 0, 0, 0, 1, 1, 3, 9, 8, 7])
    }

    @Test func audioFrameWireBytesArePinned() {
        let m = AudioFrame(sampleRate: 44100, channels: 2, ptsMicros: 123, data: [1, 2])
        #expect(Frame.encodeAny(.audioFrame(m)) == [17, 17, 0, 0, 172, 68, 2, 0, 0, 0, 0, 0, 0, 0, 123, 2, 1, 2])
    }

    @Test func viewportWireBytesArePinned() {
        let m = Viewport(displayID: 1, x: 0, y: 0, w: 65535, h: 65535)
        #expect(Frame.encodeAny(.viewport(m)) == [13, 18, 0, 0, 0, 1, 0, 0, 0, 0, 255, 255, 255, 255])
    }

    @Test func qualityStatsWireBytesArePinned() {
        let m = QualityStats(displayID: 1, encoderWidth: 1920, encoderHeight: 1080, configuredBitrate: 8_000_000,
                              encodedMbpsX100: 500, fpsX100: 6000, averageFrameBytes: 1000, keyframes: 1,
                              averageEncodeMsX100: 200, viewportX: 0, viewportY: 0, viewportW: 65535, viewportH: 65535)
        #expect(Frame.encodeAny(.qualityStats(m)) == [45, 19, 0, 0, 0, 1, 0, 0, 7, 128, 0, 0, 4, 56, 0, 122, 18, 0, 0, 0, 1, 244, 0, 0, 23, 112, 0, 0, 3, 232, 0, 0, 0, 1, 0, 0, 0, 200, 0, 0, 0, 0, 255, 255, 255, 255])
    }

    @Test func sasClientCommitWireBytesArePinned() {
        let m = SASClientCommit(commit: Array(repeating: UInt8(0xAB), count: 32))
        #expect(Frame.encodeAny(.sasClientCommit(m)) == [33, 20, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171])
    }

    @Test func sasHostCommitWireBytesArePinned() {
        let m = SASHostCommit(commit: Array(repeating: UInt8(0xCD), count: 32))
        #expect(Frame.encodeAny(.sasHostCommit(m)) == [33, 21, 205, 205, 205, 205, 205, 205, 205, 205, 205, 205, 205, 205, 205, 205, 205, 205, 205, 205, 205, 205, 205, 205, 205, 205, 205, 205, 205, 205, 205, 205, 205, 205])
    }

    @Test func sasClientRevealWireBytesArePinned() {
        let m = SASClientReveal(nonce: Array(repeating: UInt8(0x11), count: 16))
        #expect(Frame.encodeAny(.sasClientReveal(m)) == [17, 22, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17])
    }

    @Test func sasHostRevealWireBytesArePinned() {
        let m = SASHostReveal(nonce: Array(repeating: UInt8(0x22), count: 16))
        #expect(Frame.encodeAny(.sasHostReveal(m)) == [17, 23, 34, 34, 34, 34, 34, 34, 34, 34, 34, 34, 34, 34, 34, 34, 34, 34])
    }

    @Test func sasClientConfirmWireBytesArePinned() {
        let m = SASClientConfirm(mac: Array(repeating: UInt8(0x33), count: 32))
        #expect(Frame.encodeAny(.sasClientConfirm(m)) == [33, 24, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51])
    }

    @Test func displaysUpdateWireBytesArePinned() {
        let m = DisplaysUpdate(displays: [DisplayInfo(id: 1, name: "Main", width: 1920, height: 1080, scaleX100: 200)])
        #expect(Frame.encodeAny(.displaysUpdate(m)) == [21, 25, 1, 0, 0, 0, 1, 4, 77, 97, 105, 110, 0, 0, 7, 128, 0, 0, 4, 56, 0, 200])
    }

    @Test func hostLockStatusWireBytesArePinned() {
        #expect(Frame.encodeAny(.hostLockStatus(HostLockStatus(locked: true))) == [2, 26, 1])
    }

    @Test func pingWireBytesArePinned() {
        let m = Ping(sendMicros: 1_234_567_890_123)
        #expect(Frame.encodeAny(.ping(m)) == [9, 27, 0, 0, 1, 31, 113, 251, 4, 203])
    }

    @Test func pongWireBytesArePinned() {
        let m = Pong(sendMicros: 1_234_567_890_123, hostUptimeMicros: 9_876_543_210)
        #expect(Frame.encodeAny(.pong(m)) == [17, 28, 0, 0, 1, 31, 113, 251, 4, 203, 0, 0, 0, 2, 76, 176, 22, 234])
    }

    @Test func clientFeedbackWireBytesArePinned() {
        let m = ClientFeedback(receivedFPSX100: 5_985, receivedMbpsX100: 4_275, averageDecodeMsX100: 250,
                                decodeQueueDepth: 3, droppedFrames: 7, rttMicros: 15_000)
        #expect(Frame.encodeAny(.clientFeedback(m)) == [23, 29, 0, 0, 23, 97, 0, 0, 16, 179, 0, 0, 0, 250, 0, 3, 0, 0, 0, 7, 0, 0, 58, 152])
    }
}

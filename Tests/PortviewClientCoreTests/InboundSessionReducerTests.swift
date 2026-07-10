// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import Testing
import PortviewProtocol
@testable import PortviewClientCore

/// The pure reducer behind the client session's inbound state. Driven with synthetic message
/// sequences (no live connection anywhere) and asserted as whole `Equatable` snapshots — mirrors
/// the host side's `HostSessions`.
@Suite struct InboundSessionReducerTests {
    private func display(id: UInt32, width: UInt32 = 1512, height: UInt32 = 982) -> DisplayInfo {
        DisplayInfo(id: id, name: "Display \(id)", width: width, height: height, scaleX100: 200)
    }

    private func hello(_ displays: [DisplayInfo]) -> AnyMessage {
        .serverHello(ServerHello(protocolVersion: 1, displays: displays, chosenCodec: .hevc))
    }

    private func frame(x: UInt16, y: UInt16, w: UInt16, h: UInt16) -> VideoFrame {
        VideoFrame(sequence: 1, ptsMicros: 0, isKeyframe: true, displayID: 7,
                   width: 1512, height: 982, data: [],
                   viewportX: x, viewportY: y, viewportW: w, viewportH: h)
    }

    /// A reducer mid-stream on display 7 (of 7 & 9) — the common seed for the delta tests.
    private func streaming() -> InboundSessionReducer {
        var state = InboundSessionReducer()
        state.apply(hello([display(id: 7), display(id: 9, width: 2560, height: 1440)]))
        return state
    }

    // MARK: - ServerHello

    @Test func serverHelloPopulatesDisplaysAndStreams() {
        var state = InboundSessionReducer()
        state.apply(hello([display(id: 7), display(id: 9)]))
        #expect(state.isStreaming)
        #expect(state.displays == [display(id: 7), display(id: 9)])
        #expect(state.activeDisplayID == 7)
        #expect(state.displaySize == CGSize(width: 1512, height: 982))
    }

    @Test func serverHelloWithoutDisplaysIsIgnored() {
        var state = InboundSessionReducer()
        state.apply(hello([]))
        #expect(state == InboundSessionReducer())
    }

    // MARK: - Cursor confirmations (the isClose epsilon guard)

    @Test func confirmWithinEpsilonDoesNotMoveCursor() {
        var state = streaming()
        let before = state
        // 0.5 quantizes to 32768/65535 ≈ 0.5000038 — inside the sub-pixel epsilon, so the
        // confirmation matches the local prediction and must not re-target the cursor.
        state.apply(.cursorPosition(CursorPosition(normalizedX: 0.5, normalizedY: 0.5)))
        #expect(state == before)
        #expect(state.cursorNormalized == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func confirmBeyondEpsilonMovesCursor() {
        var state = streaming()
        let confirm = CursorPosition(normalizedX: 0.6, normalizedY: 0.25)
        state.apply(.cursorPosition(confirm))
        #expect(state.cursorNormalized == CGPoint(x: confirm.normalizedX, y: confirm.normalizedY))
    }

    // MARK: - Frame viewport (the region-change guard)

    @Test func videoFrameSettlesViewportToItsRegion() {
        var state = streaming()
        let f = frame(x: 16384, y: 8192, w: 32768, h: 32768)
        state.apply(.videoFrame(f))
        #expect(state.frameViewport == CGRect(x: f.normalizedViewportX, y: f.normalizedViewportY,
                                              width: f.normalizedViewportW, height: f.normalizedViewportH))
    }

    @Test func unchangedRegionLeavesSnapshotUntouched() {
        var state = streaming()
        state.apply(.videoFrame(frame(x: 16384, y: 8192, w: 32768, h: 32768)))
        let before = state
        state.apply(.videoFrame(frame(x: 16384, y: 8192, w: 32768, h: 32768)))
        #expect(state == before)
    }

    @Test func regionChangeMovesViewport() {
        var state = streaming()
        state.apply(.videoFrame(frame(x: 16384, y: 8192, w: 32768, h: 32768)))
        let previous = state.frameViewport
        state.apply(.videoFrame(frame(x: 0, y: 0, w: 65535, h: 65535)))
        #expect(state.frameViewport != previous)
        #expect(state.frameViewport == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func legacyViewportEchoAlsoSettlesRegion() {
        var state = streaming()
        let echo = Viewport(displayID: 7, x: 4096, y: 4096, w: 16384, h: 16384)
        state.apply(.viewport(echo))
        #expect(state.frameViewport == CGRect(x: echo.normalizedX, y: echo.normalizedY,
                                              width: echo.normalizedW, height: echo.normalizedH))
        let before = state
        state.apply(.viewport(echo))
        #expect(state == before)
    }

    // MARK: - DisplaysUpdate

    @Test func vanishedStreamedDisplayRetargetsToFallback() {
        var state = streaming()
        // Move the cursor and crop off their defaults so the retarget's reset is observable.
        state.apply(.cursorPosition(CursorPosition(normalizedX: 0.8, normalizedY: 0.2)))
        state.apply(.videoFrame(frame(x: 16384, y: 16384, w: 32768, h: 32768)))
        state.apply(.displaysUpdate(DisplaysUpdate(displays: [display(id: 9, width: 2560, height: 1440)])))
        #expect(state.activeDisplayID == 9)
        #expect(state.displaySize == CGSize(width: 2560, height: 1440))
        #expect(state.cursorNormalized == CGPoint(x: 0.5, y: 0.5))
        #expect(state.frameViewport == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func survivingActiveDisplayTracksResolutionChange() {
        var state = streaming()
        state.apply(.displaysUpdate(DisplaysUpdate(displays: [display(id: 7, width: 1728, height: 1117),
                                                              display(id: 9, width: 2560, height: 1440)])))
        #expect(state.activeDisplayID == 7)
        #expect(state.displaySize == CGSize(width: 1728, height: 1117))
        #expect(state.displays.count == 2)
    }

    @Test func emptyDisplaysUpdateLeavesActiveDisplayUntouched() {
        var state = streaming()
        state.apply(.displaysUpdate(DisplaysUpdate(displays: [])))
        #expect(state.displays.isEmpty)
        #expect(state.activeDisplayID == 7)
        #expect(state.displaySize == CGSize(width: 1512, height: 982))
    }

    // MARK: - Host lock

    @Test func hostLockStatusToggles() {
        var state = streaming()
        state.apply(.hostLockStatus(HostLockStatus(locked: true)))
        #expect(state.hostLocked)
        let before = state
        state.apply(.hostLockStatus(HostLockStatus(locked: true)))
        #expect(state == before)
        state.apply(.hostLockStatus(HostLockStatus(locked: false)))
        #expect(!state.hostLocked)
    }

    // MARK: - Effect-only messages

    @Test func effectOnlyMessagesAreIgnored() {
        var state = streaming()
        let before = state
        state.apply(.clipboardUpdate(ClipboardUpdate(text: "hi")))
        state.apply(.pong(Pong(sendMicros: 1, hostUptimeMicros: 2)))
        state.apply(.bye(Bye(reason: "done")))
        #expect(state == before)
    }
}

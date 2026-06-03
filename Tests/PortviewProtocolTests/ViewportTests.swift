import Testing
@testable import PortviewProtocol

@Suite struct ViewportTests {
    @Test func viewportRoundTrips() throws {
        let message = Viewport(displayID: 7, x: 100, y: 200, w: 30000, h: 40000)
        var w = BinaryWriter()
        message.encode(into: &w)
        var r = BinaryReader(w.bytes)
        #expect(try Viewport(from: &r) == message)
        #expect(Viewport.messageType == .viewport)
    }

    @Test func normalizedInitClampsToScreen() {
        // Origin pushed past the edge for the given size is clamped so x+w (and y+h) stay ≤ 1.
        let vp = Viewport(displayID: 1, normalizedX: 0.9, normalizedY: 0.9, normalizedW: 0.5, normalizedH: 0.5)
        #expect(abs(vp.normalizedW - 0.5) < 0.001)
        #expect(vp.normalizedX + vp.normalizedW <= 1.0001)
        #expect(vp.normalizedY + vp.normalizedH <= 1.0001)
        // A negative size clamps to 0; a full region round-trips near 1.
        let full = Viewport(displayID: 1, normalizedX: 0, normalizedY: 0, normalizedW: 1, normalizedH: 1)
        #expect(full.normalizedW > 0.999)
    }

    @Test func viewportThroughFrame() throws {
        let any: AnyMessage = .viewport(Viewport(displayID: 2, normalizedX: 0.25, normalizedY: 0.25, normalizedW: 0.5, normalizedH: 0.5))
        #expect(try Frame.decode(Frame.encodeAny(any)) == any)
    }
}

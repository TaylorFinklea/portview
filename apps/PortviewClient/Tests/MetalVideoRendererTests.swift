import XCTest
import CoreGraphics

@testable import PortviewClient

/// The renderer's pure geometry: mapping the display-window into a frame's region (UV) and the
/// per-vsync easing. The no-jump invariant lives here now (the window→UV map keeps the on-screen
/// window fixed as the host re-crops).
@MainActor
final class MetalVideoRendererTests: XCTestCase {
    func testSampleRectIsFullWhenWindowEqualsRegion() {
        let r = MetalVideoRenderer.sampleRect(window: CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.4),
                                              in: CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.4))
        XCTAssertEqual(r.minX, 0, accuracy: 0.0001)
        XCTAssertEqual(r.minY, 0, accuracy: 0.0001)
        XCTAssertEqual(r.width, 1, accuracy: 0.0001)
        XCTAssertEqual(r.height, 1, accuracy: 0.0001)
    }

    /// THE no-jump invariant: the on-screen window must not move when the host re-crops. The window
    /// recovered from `(sampleRect, region)` must be identical for two different regions that both
    /// contain the window — so a re-crop changes which pixels/crispness, never the geometry.
    func testWindowIsInvariantToFrameRegion() {
        let window = CGRect(x: 0.40, y: 0.45, width: 0.10, height: 0.20)
        let f1 = CGRect(x: 0.35, y: 0.40, width: 0.20, height: 0.30)
        let f2 = CGRect(x: 0.30, y: 0.38, width: 0.30, height: 0.34)
        let r1 = MetalVideoRenderer.sampleRect(window: window, in: f1)
        let r2 = MetalVideoRenderer.sampleRect(window: window, in: f2)
        let w1 = recover(r1, in: f1)
        let w2 = recover(r2, in: f2)
        XCTAssertEqual(w1.minX, w2.minX, accuracy: 0.0005)
        XCTAssertEqual(w1.minY, w2.minY, accuracy: 0.0005)
        XCTAssertEqual(w1.width, w2.width, accuracy: 0.0005)
        XCTAssertEqual(w1.height, w2.height, accuracy: 0.0005)
        XCTAssertEqual(w1.minX, window.minX, accuracy: 0.0005) // and it's actually the window
    }

    /// A window past the frame edge produces out-of-[0,1] UVs (sampler edge-clamps) but keeps its true
    /// size — so the renderer aspect-fits the same on-screen rect instead of pinching to a sliver.
    func testWindowPastFrameKeepsSizeAndExceedsUnitRange() {
        let window = CGRect(x: 0.80, y: 0.10, width: 0.30, height: 0.20) // runs past region's right edge
        let region = CGRect(x: 0.50, y: 0.0, width: 0.40, height: 1.0)
        let r = MetalVideoRenderer.sampleRect(window: window, in: region)
        XCTAssertGreaterThan(r.maxX, 1.0)                 // exceeds [0,1] → sampler clamps
        XCTAssertEqual(r.width, 0.30 / 0.40, accuracy: 0.0001) // true size preserved (no pinch)
    }

    func testEasedWindowMovesTowardTargetThenSettles() {
        let target = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        var w = CGRect(x: 0, y: 0, width: 1, height: 1)
        let first = MetalVideoRenderer.easedWindow(current: w, target: target, factor: 0.3)
        XCTAssertGreaterThan(first.minX, w.minX)          // moved toward target
        XCTAssertLessThan(first.width, w.width)
        XCTAssertGreaterThan(target.minX - first.minX, 0) // not overshooting
        // Iterate to convergence, then it snaps exactly to target (so tick() can go idle).
        for _ in 0..<200 { w = MetalVideoRenderer.easedWindow(current: w, target: target, factor: 0.3) }
        XCTAssertEqual(w, target)
        XCTAssertEqual(MetalVideoRenderer.easedWindow(current: target, target: target, factor: 0.3), target)
    }

    private func recover(_ uv: CGRect, in f: CGRect) -> CGRect {
        CGRect(x: f.minX + uv.minX * f.width, y: f.minY + uv.minY * f.height,
               width: uv.width * f.width, height: uv.height * f.height)
    }
}

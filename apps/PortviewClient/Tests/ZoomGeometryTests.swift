import XCTest
import CoreGraphics

@testable import PortviewClient

/// The magnifier geometry. The broken case was an ultrawide host on a portrait phone: the old square
/// crop (`max(visW, visH)`) stayed full-display at usable zoom, so nothing was magnified. The zoom is
/// now applied by sampling `sampleRect` of the frame in the Metal shader (no CA transform).
final class ZoomGeometryTests: XCTestCase {
    private let phone = CGSize(width: 390, height: 844)
    private let ultrawide = CGSize(width: 3440, height: 1440)
    private let full = CGRect(x: 0, y: 0, width: 1, height: 1)
    private let center = CGPoint(x: 0.5, y: 0.5)

    func testZoom1OverviewRequestsFullDisplay() {
        let g = ZoomGeometry(view: phone, displaySize: ultrawide, cursor: center, zoom: 1, frameViewport: full)
        XCTAssertGreaterThanOrEqual(g.cropRequest.width, 0.99)
        XCTAssertGreaterThanOrEqual(g.cropRequest.height, 0.99)
    }

    /// No regression to the working overview: at zoom 1 the whole frame is sampled (renderer then
    /// aspect-fits it → the letterboxed overview, unchanged).
    func testZoom1OverviewSamplesWholeFrame() {
        let g = ZoomGeometry(view: phone, displaySize: ultrawide, cursor: center, zoom: 1, frameViewport: full)
        XCTAssertEqual(g.sampleRect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(g.sampleRect.minY, 0, accuracy: 0.001)
        XCTAssertEqual(g.sampleRect.width, 1, accuracy: 0.001)
        XCTAssertEqual(g.sampleRect.height, 1, accuracy: 0.001)
    }

    /// THE fix: at the zoom needed to read on a phone, the host is asked to crop a real region.
    func testHighZoomOnUltrawideRequestsCroppedRegion() {
        let g = ZoomGeometry(view: phone, displaySize: ultrawide, cursor: center, zoom: 5, frameViewport: full)
        XCTAssertLessThan(g.cropRequest.width, 0.5) // was 1.0 (whole display) before the fix
    }

    func testCropFollowsCursorHorizontally() {
        let left = ZoomGeometry(view: phone, displaySize: ultrawide, cursor: CGPoint(x: 0.2, y: 0.5), zoom: 5, frameViewport: full)
        let right = ZoomGeometry(view: phone, displaySize: ultrawide, cursor: CGPoint(x: 0.8, y: 0.5), zoom: 5, frameViewport: full)
        XCTAssertLessThan(left.cropRequest.minX, right.cropRequest.minX)
        XCTAssertLessThan(left.sampleRect.minX, right.sampleRect.minX) // the sampled region follows too
    }

    /// Zoomed in, only a sub-rect of the (already-cropped) frame is sampled, and it's finite/in-bounds.
    func testHighZoomSamplesSubRect() {
        let request = ZoomGeometry(view: phone, displaySize: ultrawide, cursor: center, zoom: 5, frameViewport: full).cropRequest
        let g = ZoomGeometry(view: phone, displaySize: ultrawide, cursor: center, zoom: 5, frameViewport: request)
        XCTAssertGreaterThan(g.sampleRect.width, 0)
        XCTAssertLessThanOrEqual(g.sampleRect.maxX, 1.0001)
        XCTAssertLessThanOrEqual(g.sampleRect.maxY, 1.0001)
        XCTAssertTrue(g.sampleRect.minX.isFinite && g.sampleRect.minY.isFinite)
    }

    /// THE no-jump invariant (Phase C): for a fixed gesture, the on-screen window must NOT move when
    /// the host re-crops. The display-region recovered as `f.origin + sampleRect.origin * f.size`
    /// (and size scaled by f) must be identical across two different frameViewports that both contain
    /// the window — so a re-crop changes which pixels/crispness, never the on-screen geometry.
    func testSampledWindowIsInvariantToFrameViewport() {
        let zoom: CGFloat = 4
        let cursor = CGPoint(x: 0.4, y: 0.55)
        // Two different host crops that both contain the window (the padded request, and a looser one).
        let f1 = ZoomGeometry(view: phone, displaySize: ultrawide, cursor: cursor, zoom: zoom, frameViewport: full).cropRequest
        let f2 = CGRect(x: max(0, f1.minX - 0.05), y: max(0, f1.minY - 0.05),
                        width: min(1, f1.width + 0.1), height: min(1, f1.height + 0.1))

        let g1 = ZoomGeometry(view: phone, displaySize: ultrawide, cursor: cursor, zoom: zoom, frameViewport: f1)
        let g2 = ZoomGeometry(view: phone, displaySize: ultrawide, cursor: cursor, zoom: zoom, frameViewport: f2)

        // Recover the sampled region back into display coords through each frame.
        let w1 = recoverWindow(g1.sampleRect, in: f1)
        let w2 = recoverWindow(g2.sampleRect, in: f2)
        XCTAssertEqual(w1.minX, w2.minX, accuracy: 0.002)
        XCTAssertEqual(w1.minY, w2.minY, accuracy: 0.002)
        XCTAssertEqual(w1.width, w2.width, accuracy: 0.002)
        XCTAssertEqual(w1.height, w2.height, accuracy: 0.002)
    }

    private func recoverWindow(_ uv: CGRect, in f: CGRect) -> CGRect {
        CGRect(x: f.minX + uv.minX * f.width, y: f.minY + uv.minY * f.height,
               width: uv.width * f.width, height: uv.height * f.height)
    }
}

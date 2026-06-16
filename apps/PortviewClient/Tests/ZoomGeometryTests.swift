import XCTest
import CoreGraphics

@testable import PortviewClient

/// The magnifier geometry. The broken case was an ultrawide host on a portrait phone: the old square
/// crop (`max(visW, visH)`) stayed full-display at usable zoom, so nothing was magnified.
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

    /// No regression to the working overview: at zoom 1 the display fits the view exactly (scale 1).
    func testZoom1OverviewRenderScaleIsOne() {
        let g = ZoomGeometry(view: phone, displaySize: ultrawide, cursor: center, zoom: 1, frameViewport: full)
        XCTAssertEqual(g.renderScale, 1, accuracy: 0.001)
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
    }

    /// Once the host confirms the crop (frameViewport == the requested crop), the render is sane.
    func testSettledCroppedFrameRendersZoomedAndFinite() {
        let request = ZoomGeometry(view: phone, displaySize: ultrawide, cursor: center, zoom: 5, frameViewport: full).cropRequest
        let settled = ZoomGeometry(view: phone, displaySize: ultrawide, cursor: center, zoom: 5, frameViewport: request)
        XCTAssertGreaterThan(settled.renderScale, 0)
        XCTAssertTrue(settled.renderScale.isFinite)
        XCTAssertTrue(settled.pan.x.isFinite && settled.pan.y.isFinite)
    }
}

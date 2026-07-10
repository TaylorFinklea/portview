// SPDX-License-Identifier: Apache-2.0
import XCTest
import CoreGraphics

import PortviewClientCore

/// The magnifier geometry. The broken case was an ultrawide host on a portrait phone: the old square
/// crop (`max(visW, visH)`) stayed full-display at usable zoom, so nothing was magnified. The zoom is
/// now applied by sampling the visible window in the Metal shader; `ZoomGeometry` computes that window
/// (display coords) + the host crop request, both independent of the current frame's region.
final class ZoomGeometryTests: XCTestCase {
    private let phone = CGSize(width: 390, height: 844)
    private let ultrawide = CGSize(width: 3440, height: 1440)
    private let center = CGPoint(x: 0.5, y: 0.5)

    func testZoom1OverviewRequestsFullDisplay() {
        let g = ZoomGeometry(view: phone, displaySize: ultrawide, cursor: center, zoom: 1)
        XCTAssertGreaterThanOrEqual(g.cropRequest.width, 0.99)
        XCTAssertGreaterThanOrEqual(g.cropRequest.height, 0.99)
    }

    /// No regression to the working overview: at zoom 1 the whole display is the visible window (the
    /// renderer then aspect-fits it → the letterboxed overview, unchanged).
    func testZoom1OverviewVisibleWindowIsFullDisplay() {
        let g = ZoomGeometry(view: phone, displaySize: ultrawide, cursor: center, zoom: 1)
        XCTAssertEqual(g.visibleWindow.minX, 0, accuracy: 0.001)
        XCTAssertEqual(g.visibleWindow.minY, 0, accuracy: 0.001)
        XCTAssertEqual(g.visibleWindow.width, 1, accuracy: 0.001)
        XCTAssertEqual(g.visibleWindow.height, 1, accuracy: 0.001)
    }

    /// THE fix: at the zoom needed to read on a phone, the host is asked to crop a real region and the
    /// visible window is a genuine sub-rect of the display.
    func testHighZoomOnUltrawideRequestsCroppedRegion() {
        let g = ZoomGeometry(view: phone, displaySize: ultrawide, cursor: center, zoom: 5)
        XCTAssertLessThan(g.cropRequest.width, 0.9) // a real crop, not the whole display (padding 1.5 → 0.8 here)
        XCTAssertLessThan(g.visibleWindow.width, 0.5) // the magnified window itself is small
        XCTAssertGreaterThan(g.visibleWindow.width, 0)
    }

    func testCropAndWindowFollowCursorHorizontally() {
        let left = ZoomGeometry(view: phone, displaySize: ultrawide, cursor: CGPoint(x: 0.2, y: 0.5), zoom: 5)
        let right = ZoomGeometry(view: phone, displaySize: ultrawide, cursor: CGPoint(x: 0.8, y: 0.5), zoom: 5)
        XCTAssertLessThan(left.cropRequest.minX, right.cropRequest.minX)
        XCTAssertLessThan(left.visibleWindow.minX, right.visibleWindow.minX)
    }

    func testVisibleWindowStaysInsideDisplay() {
        let g = ZoomGeometry(view: phone, displaySize: ultrawide, cursor: CGPoint(x: 0.95, y: 0.95), zoom: 5)
        XCTAssertGreaterThanOrEqual(g.visibleWindow.minX, -0.0001)
        XCTAssertGreaterThanOrEqual(g.visibleWindow.minY, -0.0001)
        XCTAssertLessThanOrEqual(g.visibleWindow.maxX, 1.0001)
        XCTAssertLessThanOrEqual(g.visibleWindow.maxY, 1.0001)
    }
}

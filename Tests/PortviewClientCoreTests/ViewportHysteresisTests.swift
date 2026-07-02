import XCTest
import CoreGraphics

import PortviewClientCore

/// Re-crop hysteresis: don't re-crop (call the host's SCStream.updateConfiguration, which hiccups fps)
/// while the visible window stays inside the region the host is already sending; do re-crop when it
/// nears the edge, the crop is too loose, or it's the initial zoom-in. Margins are a FRACTION of the
/// window (matching the relative crop padding), so the predicate behaves the same at any zoom.
final class ViewportHysteresisTests: XCTestCase {
    func testInRegionPanIsCovered() {
        // Window inside a reasonably-tight captured region (2× the window) → no re-crop.
        let f = CGRect(x: 0.40, y: 0.40, width: 0.20, height: 0.20)
        let w = CGRect(x: 0.47, y: 0.47, width: 0.10, height: 0.10)
        XCTAssertTrue(ViewportCoverage.windowCovered(w, by: f))
    }

    func testWindowNearEdgeTriggersRecrop() {
        // Window panned within the (fractional) margin of the captured region's right edge → re-crop.
        let f = CGRect(x: 0.40, y: 0.40, width: 0.20, height: 0.20) // right edge 0.60
        let w = CGRect(x: 0.49, y: 0.45, width: 0.10, height: 0.10) // maxX 0.59, within 0.12×0.10 of 0.60
        XCTAssertFalse(ViewportCoverage.windowCovered(w, by: f))
    }

    func testFlushWithDisplayEdgeNeedsNoMargin() {
        // Captured region pinned to the display's left/top edge: a window flush there is still covered
        // (the host can't capture past the screen, so no re-crop should fire).
        let f = CGRect(x: 0.0, y: 0.0, width: 0.20, height: 0.20)
        let w = CGRect(x: 0.0, y: 0.0, width: 0.10, height: 0.10)
        XCTAssertTrue(ViewportCoverage.windowCovered(w, by: f))
    }

    func testInitialZoomInIsNotCovered() {
        // Host still sending the full display while zoomed in (tiny window) → too loose → re-crop.
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        let w = CGRect(x: 0.45, y: 0.45, width: 0.10, height: 0.10)
        XCTAssertFalse(ViewportCoverage.windowCovered(w, by: full))
    }

    func testFreshTightCropIsCovered() {
        // Right after a re-crop the region is the padded window (≈1.5×) — must be covered so we don't
        // immediately re-crop again (the relative-margin fix; an absolute margin looped here).
        let w = CGRect(x: 0.45, y: 0.45, width: 0.10, height: 0.10)
        let f = CGRect(x: 0.425, y: 0.425, width: 0.15, height: 0.15) // window + 25% padding each side
        XCTAssertTrue(ViewportCoverage.windowCovered(w, by: f))
    }

    func testZoom1OverviewIsCovered() {
        // Full window on a full-display crop (overview) → covered, no spurious re-crop.
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        XCTAssertTrue(ViewportCoverage.windowCovered(full, by: full))
    }

    func testCoverageIsScaleInvariant() {
        // Same geometric relationship at 0.5× the size must give the same verdict (no absolute-margin
        // surprise at high zoom).
        let wBig = CGRect(x: 0.40, y: 0.40, width: 0.20, height: 0.20)
        let fBig = CGRect(x: 0.35, y: 0.35, width: 0.30, height: 0.30)
        let wSmall = CGRect(x: 0.40, y: 0.40, width: 0.04, height: 0.04)
        let fSmall = CGRect(x: 0.39, y: 0.39, width: 0.06, height: 0.06)
        XCTAssertEqual(ViewportCoverage.windowCovered(wBig, by: fBig),
                       ViewportCoverage.windowCovered(wSmall, by: fSmall))
    }
}

import CoreGraphics
import XCTest

@testable import PortviewClient

/// The cursor change-guard: a host confirmation that matches the locally-predicted cursor within
/// sub-pixel epsilon is treated as "the same" and dropped, so it doesn't re-target the cursor-follow
/// spring; a genuinely different position is not close and is applied.
final class CursorReconcileTests: XCTestCase {
    func testNearDuplicateConfirmationIsClose() {
        let predicted = CGPoint(x: 0.4, y: 0.6)
        let confirm = CGPoint(x: 0.4004, y: 0.5997)  // sub-epsilon jitter
        XCTAssertTrue(confirm.isClose(to: predicted))
    }

    func testGenuineDriftIsNotClose() {
        let predicted = CGPoint(x: 0.4, y: 0.6)
        XCTAssertFalse(CGPoint(x: 0.42, y: 0.6).isClose(to: predicted))   // x drifted
        XCTAssertFalse(CGPoint(x: 0.4, y: 0.58).isClose(to: predicted))   // y drifted
    }

    func testEpsilonBoundary() {
        let origin = CGPoint(x: 0.5, y: 0.5)
        XCTAssertTrue(CGPoint(x: 0.5 + 0.0009, y: 0.5).isClose(to: origin))
        XCTAssertFalse(CGPoint(x: 0.5 + 0.0011, y: 0.5).isClose(to: origin))
    }
}

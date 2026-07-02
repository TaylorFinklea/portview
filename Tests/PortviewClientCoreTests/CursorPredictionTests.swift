import CoreGraphics
import Testing
import PortviewClientCore

/// The client-side cursor prediction: after sending a pointer delta, the local cursor advances by the
/// exact sent delta (scaled by sensitivity, normalized by display size) and clamps to [0, 1] so the
/// zoom-follow window stays in lockstep with the host without waiting for its CursorPosition echo.
@Suite struct CursorPredictionTests {
    private let display = CGSize(width: 1000, height: 500)

    @Test func interiorMoveScalesBySensitivityOverDisplaySize() {
        let p = CursorPrediction(current: CGPoint(x: 0.5, y: 0.5), dx: 10, dy: -5,
                                 sensitivity: 1.5, displaySize: display).predicted
        #expect(abs(p.x - 0.515) < 1e-9)  // 0.5 + 10*1.5/1000
        #expect(abs(p.y - 0.485) < 1e-9)  // 0.5 + (-5)*1.5/500
    }

    @Test(arguments: [
        // (current, dx, dy, expected) — big deltas pin to the [0,1] bounds on each axis.
        (CGPoint(x: 0.9, y: 0.5), CGFloat(200), CGFloat(0), CGPoint(x: 1, y: 0.5)),   // clamp x at 1
        (CGPoint(x: 0.1, y: 0.5), CGFloat(-200), CGFloat(0), CGPoint(x: 0, y: 0.5)),  // clamp x at 0
        (CGPoint(x: 0.5, y: 0.9), CGFloat(0), CGFloat(200), CGPoint(x: 0.5, y: 1)),   // clamp y at 1
        (CGPoint(x: 0.5, y: 0.1), CGFloat(0), CGFloat(-200), CGPoint(x: 0.5, y: 0)),  // clamp y at 0
    ])
    func clampsToUnitBounds(current: CGPoint, dx: CGFloat, dy: CGFloat, expected: CGPoint) {
        let p = CursorPrediction(current: current, dx: dx, dy: dy,
                                 sensitivity: 1.5, displaySize: display).predicted
        #expect(abs(p.x - expected.x) < 1e-9)
        #expect(abs(p.y - expected.y) < 1e-9)
    }

    @Test func zeroDeltaLeavesCursorInPlace() {
        let p = CursorPrediction(current: CGPoint(x: 0.25, y: 0.75), dx: 0, dy: 0,
                                 sensitivity: 1.5, displaySize: display).predicted
        #expect(p == CGPoint(x: 0.25, y: 0.75))
    }

    @Test func doublingSensitivityDoublesDisplacement() {
        let start = CGPoint(x: 0.5, y: 0.5)
        let single = CursorPrediction(current: start, dx: 10, dy: 10,
                                      sensitivity: 1.5, displaySize: display).predicted
        let double = CursorPrediction(current: start, dx: 10, dy: 10,
                                      sensitivity: 3.0, displaySize: display).predicted
        #expect(abs((double.x - start.x) - 2 * (single.x - start.x)) < 1e-9)
        #expect(abs((double.y - start.y) - 2 * (single.y - start.y)) < 1e-9)
    }

    /// The view model never feeds a zero display (it clamps to ≥1×1 and defaults to 1×1), and the
    /// original inline math had no explicit guard — the [0,1] clamp is the only safety. Document that
    /// the clamp still pins the ±infinity that a zero dimension produces with a nonzero delta.
    @Test func zeroDisplaySizeStillClampsToUnitBounds() {
        let up = CursorPrediction(current: CGPoint(x: 0.5, y: 0.5), dx: 1, dy: 1,
                                  sensitivity: 1.5, displaySize: .zero).predicted
        #expect(up == CGPoint(x: 1, y: 1))
        let down = CursorPrediction(current: CGPoint(x: 0.5, y: 0.5), dx: -1, dy: -1,
                                    sensitivity: 1.5, displaySize: .zero).predicted
        #expect(down == CGPoint(x: 0, y: 0))
    }
}

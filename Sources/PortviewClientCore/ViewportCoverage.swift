import CoreGraphics

/// Pure hysteresis predicate for the magnifier's re-crop decision (so the edge cases are testable).
public enum ViewportCoverage {
    /// `window` is "covered" by captured region `f` — no re-crop needed — when it's inside `f` by
    /// `margin` on every side (a side flush with the display boundary needs no margin, since the host
    /// can't capture past the screen) AND `f` isn't more than `looseFactor`× the window in either
    /// dimension.
    public static func windowCovered(_ window: CGRect, by f: CGRect,
                                     marginFraction: CGFloat = 0.12, looseFactor: CGFloat = 6.0) -> Bool {
        // `looseFactor` must exceed the fresh crop's window-multiple so a just-applied crop reads as
        // covered (else it re-crops every frame): padding 1.5 → 4×window, snapped up by the ≤1.25×
        // capture-size ladder → ≤5×; 6.0 clears it.
        // Margin is a FRACTION of the window, not absolute: the crop padding is relative (0.25×window),
        // so at high zoom (tiny window) an absolute margin could exceed the padding and force a re-crop
        // every frame. `marginFraction` must stay below the padding fraction so a fresh crop is covered.
        let edge: CGFloat = 0.001
        let mx = window.width * marginFraction
        let my = window.height * marginFraction
        let coveredLeft   = window.minX >= f.minX + mx || f.minX <= edge
        let coveredRight  = window.maxX <= f.maxX - mx || f.maxX >= 1 - edge
        let coveredTop    = window.minY >= f.minY + my || f.minY <= edge
        let coveredBottom = window.maxY <= f.maxY - my || f.maxY >= 1 - edge
        let tightEnough = f.width <= window.width * looseFactor && f.height <= window.height * looseFactor
        return coveredLeft && coveredRight && coveredTop && coveredBottom && tightEnough
    }
}

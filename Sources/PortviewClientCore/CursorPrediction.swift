// SPDX-License-Identifier: Apache-2.0
import CoreGraphics

/// Pure arithmetic for the client-side cursor prediction. After a pointer delta is sent, the local
/// cursor advances by that exact delta (scaled by the input sensitivity, normalized by the display
/// size) and clamps to [0, 1], so the zoom-follow window tracks instantly and stays in lockstep with
/// the host's later `CursorPosition` echo (no snap).
public struct CursorPrediction {
    /// The predicted cursor in normalized display coords, clamped to the unit square.
    public let predicted: CGPoint

    public init(current: CGPoint, dx: CGFloat, dy: CGFloat, sensitivity: CGFloat, displaySize: CGSize) {
        let nx = min(1, max(0, current.x + dx * sensitivity / displaySize.width))
        let ny = min(1, max(0, current.y + dy * sensitivity / displaySize.height))
        predicted = CGPoint(x: nx, y: ny)
    }
}

// SPDX-License-Identifier: Apache-2.0
import Foundation

struct CaptureSizing {
    struct Size: Equatable, Hashable {
        var width: Int
        var height: Int
    }

    static func outputSize(width: Int, height: Int, pointPixelScale _: Float) -> Size {
        Size(width: max(1, width), height: max(1, height))
    }

    /// Snap a normalized crop fraction (0…1) UP onto a coarse geometric ladder (`ratio` rungs). The
    /// magnifier captures `setViewport`'s crop at this snapped size, so the captured region only takes
    /// a handful of discrete sizes across the whole zoom range instead of changing continuously.
    /// Snapping UP keeps the captured region ⊇ the requested one (never crops away the visible edge).
    /// Idempotent (a value already on a rung maps to itself), so the host's sourceRect and encoder
    /// output — both derived from this — stay in exact agreement (no stretch).
    static func snapCropFraction(_ fraction: Double) -> Double {
        let f = min(1, max(0, fraction))
        guard f > 0 else { return 0 }
        // Largest k with ratio^k ≥ f  ⇒  k = floor(log(f)/log(ratio)); the tiny epsilon keeps a value
        // sitting exactly on a rung from drifting to the next one through float error (idempotency).
        let k = max(0, Int((log(f) / log(ladderRatio) + 1e-9).rounded(.down)))
        return min(1, pow(ladderRatio, Double(k)))
    }

    /// Encoder output size for a magnifier crop: the crop's pixels at the SNAPPED fraction (see
    /// `snapCropFraction`), capped to the display (no upscale past native), floored to a minimum, and
    /// even for the codec. Because the snap is discrete, a continuous pinch changes the output size —
    /// and therefore reconfigures SCStream / rebuilds the VideoToolbox encoder — only a handful of
    /// times rather than on nearly every step (the old per-pixel snap was the rapid-zoom crash).
    static func cropOutputSize(displayWidth: Int, displayHeight: Int, normalizedW: Double, normalizedH: Double) -> Size {
        Size(width: clampDimension(Double(displayWidth) * snapCropFraction(normalizedW), cap: displayWidth),
             height: clampDimension(Double(displayHeight) * snapCropFraction(normalizedH), cap: displayHeight))
    }

    /// Whether re-cropping the live capture needs a forced HEVC keyframe. A pure PAN moves only the
    /// `sourceRect` while the encoder output size stays put (`from == to`): the existing P-frame stream
    /// stays valid across it, so no IDR is needed. Only a size change — a zoom-rung crossing — actually
    /// changes the decoder dimensions and requires a keyframe. Forcing one on every pan step (the old
    /// behavior) put ~6.6 large keyframes/sec on the wire during a sustained pan → a periodic hitch.
    static func cropRequiresKeyframe(from: Size, to: Size) -> Bool {
        from != to
    }

    private static let minimumDimension = 64
    private static let ladderRatio = 0.8  // ~25% resolution deadband between adjacent rungs

    private static func clampDimension(_ raw: Double, cap: Int) -> Int {
        let even = Int((raw / 2).rounded()) * 2
        return min(cap - (cap % 2), max(minimumDimension, even))
    }
}

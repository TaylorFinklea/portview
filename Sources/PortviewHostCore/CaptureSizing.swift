struct CaptureSizing {
    struct Size: Equatable {
        var width: Int
        var height: Int
    }

    static func outputSize(width: Int, height: Int, pointPixelScale _: Float) -> Size {
        Size(width: max(1, width), height: max(1, height))
    }

    /// Encoder output size for a magnifier crop: the crop's native pixels, capped to the display
    /// (no upscale), floored to a minimum, and quantized to a multiple of `quantum` (keeps the
    /// dimensions even for the codec AND stable under small pan deltas so the stream isn't
    /// reconfigured on sub-step jitter). Matching the output aspect to the crop avoids stretching.
    static func cropOutputSize(displayWidth: Int, displayHeight: Int, normalizedW: Double, normalizedH: Double) -> Size {
        Size(width: quantizedDimension(Double(displayWidth) * normalizedW, cap: displayWidth),
             height: quantizedDimension(Double(displayHeight) * normalizedH, cap: displayHeight))
    }

    private static let quantum = 16
    private static let minimumDimension = 64

    private static func quantizedDimension(_ raw: Double, cap: Int) -> Int {
        let clamped = min(Double(cap), max(0, raw))
        let snapped = Int((clamped / Double(quantum)).rounded()) * quantum
        return min(cap, max(minimumDimension, snapped))
    }
}

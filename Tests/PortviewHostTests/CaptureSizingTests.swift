import Testing
@testable import PortviewHostCore

@Suite struct CaptureSizingTests {
    @Test func pointPixelScaleDoesNotInflateInteractiveOutput() {
        let size = CaptureSizing.outputSize(width: 1710, height: 1107, pointPixelScale: 2.0)

        #expect(size == CaptureSizing.Size(width: 1710, height: 1107))
    }

    @Test func invalidOrSubOneScaleDoesNotDownscale() {
        #expect(CaptureSizing.outputSize(width: 1710, height: 1107, pointPixelScale: 0) == CaptureSizing.Size(width: 1710, height: 1107))
        #expect(CaptureSizing.outputSize(width: 1710, height: 1107, pointPixelScale: 0.5) == CaptureSizing.Size(width: 1710, height: 1107))
    }

    // MARK: - Magnifier crop output sizing (discrete-ladder region streaming)

    @Test func snapCropFractionSnapsUpOntoADiscreteLadder() {
        // Always covers the requested region (≥ input), never exceeds 1, and is idempotent so the
        // host's sourceRect and encoder output (both derived from it) agree exactly.
        for f in stride(from: 0.03, through: 1.0, by: 0.001) {
            let s = CaptureSizing.snapCropFraction(f)
            #expect(s >= f - 1e-9 && s <= 1.0)
            #expect(abs(CaptureSizing.snapCropFraction(s) - s) < 1e-9)  // idempotent
        }
        // A full zoom sweep collapses to only a handful of distinct rungs (not hundreds).
        let rungs = Set(stride(from: 0.03, through: 1.0, by: 0.001).map { CaptureSizing.snapCropFraction($0) })
        #expect(rungs.count <= 16)
    }

    @Test func cropOutputMatchesSnappedFractionPixels() {
        // The output is the snapped fraction's pixels — so it equals the captured region's pixels and
        // can't stretch. (0.232 snaps up to a rung; height 1.0 stays full.)
        let snw = CaptureSizing.snapCropFraction(0.232)
        let size = CaptureSizing.cropOutputSize(displayWidth: 3440, displayHeight: 1440, normalizedW: 0.232, normalizedH: 1.0)
        #expect(size.width == 2 * Int((Double(3440) * snw / 2).rounded()))
        #expect(size.height == 1440)
        #expect(size.width <= 3440 && size.width % 2 == 0)
    }

    @Test func cropOutputNeverExceedsDisplayNative() {
        let size = CaptureSizing.cropOutputSize(displayWidth: 3440, displayHeight: 1440, normalizedW: 1.0, normalizedH: 1.0)
        #expect(size == CaptureSizing.Size(width: 3440, height: 1440))
    }

    @Test func cropOutputHasMinFloorAndIsAlwaysEven() {
        let tiny = CaptureSizing.cropOutputSize(displayWidth: 3440, displayHeight: 1440, normalizedW: 0.001, normalizedH: 0.001)
        #expect(tiny.width >= 64 && tiny.height >= 64)
        #expect(tiny.width % 2 == 0 && tiny.height % 2 == 0)
    }

    @Test func cropOutputIsStableUnderTinyZoomDeltas() {
        // Two nearby zoom levels inside the same ladder rung must produce the SAME output size, so a
        // sub-rung pinch jitter doesn't reconfigure the stream/encoder.
        let a = CaptureSizing.cropOutputSize(displayWidth: 3440, displayHeight: 1440, normalizedW: 0.18, normalizedH: 1.0)
        let b = CaptureSizing.cropOutputSize(displayWidth: 3440, displayHeight: 1440, normalizedW: 0.19, normalizedH: 1.0)
        #expect(a == b)
    }

    @Test func cropOutputIsDiscreteAndMonotonicAcrossAZoomSweep() {
        // Sweep a full-height slice from wide to narrow (zoom in). The output width must be
        // non-increasing (monotonic) and take only a handful of DISTINCT values across the sweep —
        // the whole point of the ladder vs. the old per-pixel snap (~215 widths on a 3440 display).
        var sizes: [CaptureSizing.Size] = []
        var nw = 0.45
        while nw >= 0.03 {
            sizes.append(CaptureSizing.cropOutputSize(displayWidth: 3440, displayHeight: 1440, normalizedW: nw, normalizedH: 1.0))
            nw -= 0.002  // 210 fine steps
        }
        let widths = sizes.map(\.width)
        #expect(widths == widths.sorted(by: >))            // non-increasing as we zoom in
        #expect(Set(sizes).count <= 20)                    // discrete: ≤20 distinct sizes, not ~210
        #expect(sizes.allSatisfy { $0.width % 2 == 0 && $0.height % 2 == 0 })
    }
}

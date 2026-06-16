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

    // MARK: - Magnifier crop output sizing (region streaming)

    @Test func cropOutputMatchesCropPixelsQuantizedEven() {
        // A narrow portrait slice of a 3440×1440 ultrawide → encoded at ~its native pixels (mod-16).
        let size = CaptureSizing.cropOutputSize(displayWidth: 3440, displayHeight: 1440, normalizedW: 0.232, normalizedH: 1.0)
        #expect(size == CaptureSizing.Size(width: 800, height: 1440)) // 0.232*3440=798→800; 1440 stays
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
}

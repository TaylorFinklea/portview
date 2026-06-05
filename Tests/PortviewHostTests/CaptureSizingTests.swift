import Testing
@testable import portview_host

@Suite struct CaptureSizingTests {
    @Test func pointPixelScaleProducesBackingPixelOutput() {
        let size = CaptureSizing.outputSize(width: 1710, height: 1107, pointPixelScale: 2.0)

        #expect(size == CaptureSizing.Size(width: 3420, height: 2214))
    }

    @Test func invalidOrSubOneScaleDoesNotDownscale() {
        #expect(CaptureSizing.outputSize(width: 1710, height: 1107, pointPixelScale: 0) == CaptureSizing.Size(width: 1710, height: 1107))
        #expect(CaptureSizing.outputSize(width: 1710, height: 1107, pointPixelScale: 0.5) == CaptureSizing.Size(width: 1710, height: 1107))
    }
}

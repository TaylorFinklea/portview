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
}

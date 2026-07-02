import Testing
import Foundation
import CoreMedia
import CoreVideo
@testable import PortviewMedia

@Suite struct VideoEncoderTests {
    /// Bitrate can be updated on the live session (no rebuild) and a subsequent encode still succeeds.
    @Test func setAverageBitRateUpdatesLiveSessionAndKeepsEncoding() async throws {
        let width = 320, height = 240
        let encoder = try VideoEncoder(width: width, height: height, averageBitRate: 12_000_000)
        #expect(encoder.averageBitRate == 12_000_000)

        encoder.setAverageBitRate(4_000_000)
        #expect(encoder.averageBitRate == 4_000_000)

        let input = makeSolidBGRA(width: width, height: height, b: 10, g: 20, r: 200)
        let encoded = try await encoder.encode(input, presentationTime: .zero)
        #expect(CMSampleBufferGetTotalSampleSize(encoded) > 0)
    }
}

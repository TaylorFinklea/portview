// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import PortviewProtocol

@Suite struct QualityStatsTests {
    @Test func qualityStatsRoundTrips() throws {
        let message = QualityStats(
            displayID: 7,
            encoderWidth: 3024,
            encoderHeight: 1964,
            configuredBitrate: 80_000_000,
            encodedMbpsX100: 4_275,
            fpsX100: 5_975,
            averageFrameBytes: 89_123,
            keyframes: 1,
            averageEncodeMsX100: 367,
            viewportX: 1_000,
            viewportY: 2_000,
            viewportW: 40_000,
            viewportH: 50_000
        )

        var writer = BinaryWriter()
        message.encode(into: &writer)
        var reader = BinaryReader(writer.bytes)

        #expect(try QualityStats(from: &reader) == message)
        #expect(QualityStats.messageType == .qualityStats)
    }

    @Test func qualityStatsThroughFrame() throws {
        let message = QualityStats(
            displayID: 2,
            encoderWidth: 1920,
            encoderHeight: 1080,
            configuredBitrate: 40_000_000,
            encodedMbpsX100: 2_500,
            fpsX100: 6_000,
            averageFrameBytes: 52_083,
            keyframes: 0,
            averageEncodeMsX100: 210,
            viewportX: 0,
            viewportY: 0,
            viewportW: 65_535,
            viewportH: 65_535
        )

        #expect(try Frame.decode(Frame.encode(message)) == .qualityStats(message))
    }
}

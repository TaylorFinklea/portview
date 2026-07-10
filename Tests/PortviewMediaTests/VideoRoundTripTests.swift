// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import CoreMedia
import CoreVideo
@testable import PortviewMedia

@Suite struct VideoRoundTripTests {
    /// A synthetic frame survives hardware HEVC encode → decode with the colour recovered
    /// (within lossy-codec tolerance) and dimensions preserved. Proves the codec core works
    /// end to end on this machine with no screen-capture permission or GUI.
    @Test func encodeThenDecodeRecoversColorAndDimensions() async throws {
        let width = 320, height = 240
        let (inB, inG, inR): (UInt8, UInt8, UInt8) = (10, 20, 200) // a strong red

        let input = makeSolidBGRA(width: width, height: height, b: inB, g: inG, r: inR)
        let encoder = try VideoEncoder(width: width, height: height)
        let encoded = try await encoder.encode(input, presentationTime: .zero)

        // The encoded buffer must carry data and a format description (VPS/SPS/PPS).
        #expect(CMSampleBufferGetTotalSampleSize(encoded) > 0)
        #expect(CMSampleBufferGetFormatDescription(encoded) != nil)

        let decoder = VideoDecoder()
        let output = try await decoder.decode(encoded)

        #expect(CVPixelBufferGetWidth(output) == width)
        #expect(CVPixelBufferGetHeight(output) == height)

        let (b, g, r) = centerPixelBGRA(output)
        #expect(abs(Int(r) - Int(inR)) < 30)
        #expect(abs(Int(g) - Int(inG)) < 30)
        #expect(abs(Int(b) - Int(inB)) < 30)
    }
}

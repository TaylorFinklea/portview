import Testing
import Foundation
import CoreMedia
import CoreVideo
@testable import PortholeMedia

@Suite struct VideoSerializerTests {
    @Test func encodedSamplePacksAndUnpacks() throws {
        let sample = EncodedVideoSample(
            parameterSets: [[1, 2, 3], [4, 5], [6]],
            data: [10, 20, 30, 40],
            isKeyframe: true
        )
        let restored = try EncodedVideoSample(serialized: sample.serialized())
        #expect(restored == sample)
    }

    /// Full media-over-bytes path: encode → serialize to bytes → unpack → rebuild
    /// sample buffer → decode, recovering the colour. This is exactly what travels
    /// over the wire inside a `VideoFrame.data` payload.
    @Test func encodeSerializeBytesDeserializeDecodeRecoversColor() async throws {
        let width = 320, height = 240
        let (inB, inG, inR): (UInt8, UInt8, UInt8) = (200, 30, 15) // a strong blue

        let input = makeSolidBGRA(width: width, height: height, b: inB, g: inG, r: inR)
        let encoder = try VideoEncoder(width: width, height: height)
        let encoded = try await encoder.encode(input, presentationTime: .zero)

        // Serialize → bytes → unpack (the round-trip a VideoFrame.data would make).
        let sample = try VideoSampleSerializer.serialize(encoded)
        #expect(sample.isKeyframe)
        #expect(!sample.parameterSets.isEmpty)
        let wireBytes = sample.serialized()
        let restored = try EncodedVideoSample(serialized: wireBytes)

        // Rebuild a decodable sample buffer and decode it.
        let rebuilt = try VideoSampleSerializer.deserialize(restored)
        let decoder = VideoDecoder()
        let output = try await decoder.decode(rebuilt)

        #expect(CVPixelBufferGetWidth(output) == width)
        #expect(CVPixelBufferGetHeight(output) == height)
        let (b, g, r) = centerPixelBGRA(output)
        #expect(abs(Int(r) - Int(inR)) < 30)
        #expect(abs(Int(g) - Int(inG)) < 30)
        #expect(abs(Int(b) - Int(inB)) < 30)
    }
}

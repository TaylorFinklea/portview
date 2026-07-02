import Testing
import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
@testable import PortviewMedia

/// A `VTDecompressionSession` invalidated out-of-band (e.g. by app backgrounding) surfaces
/// `kVTInvalidSessionErr` on the next decode. The decoder must rebuild the session and retry once
/// so the stream recovers instead of wedging on `decodeFailed`.
@Suite struct VideoDecoderRecoveryTests {
    @Test func classifiesInvalidSessionAndMalfunctionAsRecoverable() {
        #expect(VideoDecoder.isRecoverableSessionStatus(kVTInvalidSessionErr) == true)
        #expect(VideoDecoder.isRecoverableSessionStatus(kVTVideoDecoderMalfunctionErr) == true)
        // A generic decode failure (not a session-lifecycle error) is NOT retried — surface it.
        #expect(VideoDecoder.isRecoverableSessionStatus(kVTVideoDecoderBadDataErr) == false)
        #expect(VideoDecoder.isRecoverableSessionStatus(noErr) == false)
    }

    @Test func decodeRecoversAfterSessionInvalidated() async throws {
        let width = 320, height = 240
        let input = makeSolidBGRA(width: width, height: height, b: 10, g: 20, r: 200)
        let encoder = try VideoEncoder(width: width, height: height)
        let encoded = try await encoder.encode(input, presentationTime: .zero)

        let decoder = VideoDecoder()
        // First decode establishes the session.
        _ = try await decoder.decode(encoded)

        // Simulate the backgrounding hazard: invalidate the live session out-of-band while the decoder
        // still holds it, so the next decode hits kVTInvalidSessionErr.
        decoder.invalidateUnderlyingSessionForTesting()

        // Must recover (rebuild + retry once) rather than throw.
        let output = try await decoder.decode(encoded)
        #expect(CVPixelBufferGetWidth(output) == width)
        #expect(CVPixelBufferGetHeight(output) == height)
    }
}

// SPDX-License-Identifier: Apache-2.0
import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Hardware HEVC/H.264 decoder wrapping `VTDecompressionSession`, producing BGRA pixel buffers.
/// The session is (re)built lazily from each sample buffer's format description.
public final class VideoDecoder: @unchecked Sendable {
    private var session: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?

    public init() {}

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// Decode one encoded sample buffer into a BGRA pixel buffer.
    public func decode(_ sampleBuffer: CMSampleBuffer) async throws -> CVPixelBuffer {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw VideoCodecError.noOutput
        }
        if session == nil || !CMFormatDescriptionEqual(format, otherFormatDescription: formatDescription) {
            try rebuildSession(formatDescription: format)
            formatDescription = format
        }
        do {
            return try await decodeOnce(sampleBuffer)
        } catch VideoCodecError.decodeFailed(let status) where Self.isRecoverableSessionStatus(status) {
            // The decode session was invalidated out-of-band — typically VideoToolbox tears it down
            // when the app is backgrounded, and it never recovers on its own. Rebuild from the current
            // format and retry the decode once so the stream heals instead of wedging on decodeFailed.
            try rebuildSession(formatDescription: format)
            formatDescription = format
            return try await decodeOnce(sampleBuffer)
        }
    }

    /// One decode attempt against the current session. A non-`noErr` status (synchronous or from the
    /// async callback) surfaces as `VideoCodecError.decodeFailed(status)` so `decode` can decide
    /// whether it's a recoverable session-lifecycle error worth a rebuild-and-retry.
    private func decodeOnce(_ sampleBuffer: CMSampleBuffer) async throws -> CVPixelBuffer {
        guard let session else { throw VideoCodecError.decodeFailed(noErr) }

        let boxed: UncheckedSendableBox<CVPixelBuffer> = try await withCheckedThrowingContinuation { cont in
            let status = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sampleBuffer,
                flags: [._EnableAsynchronousDecompression],
                infoFlagsOut: nil
            ) { status, _, imageBuffer, _, _ in
                if status != noErr {
                    cont.resume(throwing: VideoCodecError.decodeFailed(status))
                } else if let imageBuffer {
                    cont.resume(returning: UncheckedSendableBox(value: imageBuffer))
                } else {
                    cont.resume(throwing: VideoCodecError.noOutput)
                }
            }
            if status != noErr {
                cont.resume(throwing: VideoCodecError.decodeFailed(status))
            }
        }
        return boxed.value
    }

    /// `kVTInvalidSessionErr` / `kVTVideoDecoderMalfunctionErr` mean the decode session is no longer
    /// usable (the backgrounding hazard) and is recoverable by rebuilding it. Any other status (bad
    /// data, etc.) is a real decode failure and is surfaced to the caller unchanged.
    static func isRecoverableSessionStatus(_ status: OSStatus) -> Bool {
        status == kVTInvalidSessionErr || status == kVTVideoDecoderMalfunctionErr
    }

    private func rebuildSession(formatDescription: CMFormatDescription) throws {
        if let session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
        let destinationAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: destinationAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &created
        )
        guard status == noErr, let created else {
            throw VideoCodecError.sessionCreateFailed(status)
        }
        session = created
    }

    /// Test seam: invalidate the live session out-of-band while keeping the reference, reproducing the
    /// backgrounding hazard where the next decode returns `kVTInvalidSessionErr`.
    func invalidateUnderlyingSessionForTesting() {
        if let session { VTDecompressionSessionInvalidate(session) }
    }
}

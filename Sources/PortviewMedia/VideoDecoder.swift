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
}

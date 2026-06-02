import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Hardware HEVC (H.265) encoder in low-latency mode, wrapping `VTCompressionSession`.
/// One pixel buffer in → one encoded `CMSampleBuffer` out.
public final class VideoEncoder: @unchecked Sendable {
    private let session: VTCompressionSession

    public init(width: Int, height: Int, codec: CMVideoCodecType = kCMVideoCodecType_HEVC) throws {
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue!,
        ]
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codec,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let session = created else {
            throw VideoCodecError.sessionCreateFailed(status)
        }
        self.session = session

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    /// Encode one pixel buffer; returns the encoded sample buffer (keyframe by default).
    public func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, forceKeyframe: Bool = true) async throws -> CMSampleBuffer {
        let boxed: UncheckedSendableBox<CMSampleBuffer> = try await withCheckedThrowingContinuation { cont in
            let frameProperties: [CFString: Any]? = forceKeyframe
                ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!]
                : nil
            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: presentationTime,
                duration: .invalid,
                frameProperties: frameProperties as CFDictionary?,
                infoFlagsOut: nil
            ) { status, _, sampleBuffer in
                if status != noErr {
                    cont.resume(throwing: VideoCodecError.encodeFailed(status))
                } else if let sampleBuffer {
                    cont.resume(returning: UncheckedSendableBox(value: sampleBuffer))
                } else {
                    cont.resume(throwing: VideoCodecError.noOutput)
                }
            }
            if status != noErr {
                cont.resume(throwing: VideoCodecError.encodeFailed(status))
            }
        }
        return boxed.value
    }
}

// SPDX-License-Identifier: Apache-2.0
import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Hardware HEVC (H.265) encoder in low-latency mode, wrapping `VTCompressionSession`.
/// One pixel buffer in → one encoded `CMSampleBuffer` out.
public final class VideoEncoder: @unchecked Sendable {
    private let session: VTCompressionSession
    public private(set) var averageBitRate: Int

    public init(width: Int, height: Int, codec: CMVideoCodecType = kCMVideoCodecType_HEVC,
                averageBitRate: Int? = nil) throws {
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
        // Set an explicit target bitrate (VideoToolbox's default is conservative → soft text). The
        // whole display is encoded at this rate and the client digitally zooms into it, so bits per
        // pixel is what makes zoomed-in text crisp. Heuristic ≈ 0.3 bits/pixel/frame × 60 fps; on a
        // LAN/QUIC link bandwidth isn't the constraint, so this is generous (clamped 12–80 Mbps).
        // Callers can override.
        let bitRate = averageBitRate ?? min(80_000_000, max(12_000_000, Int(Double(width * height) * 18.0)))
        self.averageBitRate = bitRate
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitRate as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    /// Updates the target bitrate on the LIVE session — VideoToolbox supports this without a
    /// session rebuild or a forced keyframe.
    public func setAverageBitRate(_ bps: Int) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
        averageBitRate = bps
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

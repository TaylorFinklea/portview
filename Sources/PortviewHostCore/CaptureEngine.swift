import Foundation
@preconcurrency import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreVideo

/// A captured screen frame. `@unchecked Sendable`: ScreenCaptureKit hands us a fresh
/// pixel buffer per callback that we forward without concurrent mutation.
struct SendableFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let pts: CMTime
}

/// A slice of captured system audio, already converted to non-interleaved Float32 PCM
/// (plane 0 then plane 1 …).
struct SendableAudioFrame: Sendable {
    let sampleRate: UInt32
    let channels: UInt8
    let ptsMicros: UInt64
    let data: [UInt8]
}

private actor ViewportState {
    private var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var keyframeRequested = false

    func get() -> CGRect { rect }

    func set(_ rect: CGRect, requestKeyframe: Bool) {
        self.rect = rect
        if requestKeyframe {
            keyframeRequested = true
        }
    }

    func consumeKeyframeRequest() -> Bool {
        let requested = keyframeRequested
        keyframeRequested = false
        return requested
    }
}

/// Captures a display with ScreenCaptureKit and exposes frames as an `AsyncStream`.
/// `.bufferingNewest(2)` drops stale frames so latency can't accumulate behind a slow encoder.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "portview.capture")
    private let audioQueue = DispatchQueue(label: "portview.capture.audio")
    private let viewportState = ViewportState()
    private let continuation: AsyncStream<SendableFrame>.Continuation
    let frames: AsyncStream<SendableFrame>
    private let audioContinuation: AsyncStream<SendableAudioFrame>.Continuation
    let audioFrames: AsyncStream<SendableAudioFrame>
    let width: Int
    let height: Int

    // Audio is converted to a canonical non-interleaved Float32 format; the converter is
    // (re)built from the first audio buffer's format.
    private var audioConverter: AVAudioConverter?
    private var audioOutputFormat: AVAudioFormat?

    // Retained so `setViewport` can re-crop the live stream (the "magnifier"): it updates both the
    // captured region (`sourceRect`) AND the output dimensions to the crop's aspect, so the region
    // is encoded 1:1 — full resolution, no stretch — which is what makes high zoom crisp.
    private var config: SCStreamConfiguration?

    func currentViewport() async -> CGRect { await viewportState.get() }
    func consumeKeyframeRequest() async -> Bool { await viewportState.consumeKeyframeRequest() }

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        (frames, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(2))
        (audioFrames, audioContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
        super.init()
    }

    func start(display: SCDisplay, maxFPS: Int) throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let outputSize = CaptureSizing.outputSize(
            width: width, height: height, pointPixelScale: filter.pointPixelScale
        )
        let config = SCStreamConfiguration()
        config.width = outputSize.width
        config.height = outputSize.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(maxFPS))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.capturesAudio = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        self.stream = stream
        self.config = config
        stream.startCapture { error in
            if let error { print("capture start error: \(error)") }
        }
    }

    /// Re-crop the live capture to a normalized region of the display (the magnifier). Sets both the
    /// captured region (`sourceRect`) AND the output dimensions to the crop's aspect (`cropOutputSize`),
    /// so the region is encoded 1:1 at full resolution without stretching — VNC-style region streaming.
    /// Output dims change only when the crop *size* changes (i.e. on zoom), so panning at a fixed zoom
    /// only moves `sourceRect` (cheap, no encoder rebuild). Returns `true` once the new configuration is
    /// in effect, so the caller confirms the crop to the client only when frames really reflect it. A
    /// no-op change (same rect and output dims) returns `true` without reconfiguring.
    func setViewport(normalizedX nx: Double, normalizedY ny: Double,
                     normalizedW nw: Double, normalizedH nh: Double) async -> Bool {
        guard let stream, let config else { return false }
        // Near-full (within 1%) → no crop; `.zero` captures the whole display at native dims.
        let cropping = !(nw >= 0.99 && nh >= 0.99)
        let normalizedRect: CGRect = cropping
            ? CGRect(x: nx, y: ny, width: nw, height: nh)
            : CGRect(x: 0, y: 0, width: 1, height: 1)
        let newRect: CGRect = cropping
            ? CGRect(x: nx * Double(width), y: ny * Double(height),
                     width: nw * Double(width), height: nh * Double(height))
            : .zero
        let outputSize = cropping
            ? CaptureSizing.cropOutputSize(displayWidth: width, displayHeight: height, normalizedW: nw, normalizedH: nh)
            : CaptureSizing.Size(width: width, height: height)

        let current = config.sourceRect
        let unchangedRect = abs(newRect.minX - current.minX) < 1 && abs(newRect.minY - current.minY) < 1
            && abs(newRect.width - current.width) < 1 && abs(newRect.height - current.height) < 1
        let unchangedSize = config.width == outputSize.width && config.height == outputSize.height
        if unchangedRect && unchangedSize {
            await viewportState.set(normalizedRect, requestKeyframe: false)
            return true
        }
        config.sourceRect = newRect
        config.width = outputSize.width
        config.height = outputSize.height
        do {
            try await stream.updateConfiguration(config)
            await viewportState.set(normalizedRect, requestKeyframe: true)
            return true
        } catch {
            print("viewport update failed: \(error)")
            return false
        }
    }

    func stop() {
        stream?.stopCapture { _ in }
        continuation.finish()
        audioContinuation.finish()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        switch outputType {
        case .screen:
            guard CMSampleBufferGetNumSamples(sampleBuffer) > 0,
                  CMSampleBufferIsValid(sampleBuffer),
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            continuation.yield(SendableFrame(pixelBuffer: pixelBuffer, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
        case .audio:
            handleAudio(sampleBuffer)
        default:
            break
        }
    }

    /// Convert one system-audio sample buffer to non-interleaved Float32 and yield it.
    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferIsValid(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        guard let sourceBuffer = Self.pcmBuffer(from: sampleBuffer, format: sourceFormat) else { return }

        let channels = min(sourceFormat.channelCount, 2)
        if audioConverter == nil
            || audioOutputFormat?.sampleRate != sourceFormat.sampleRate
            || audioOutputFormat?.channelCount != channels {
            let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: sourceFormat.sampleRate,
                                          channels: channels, interleaved: false)
            audioOutputFormat = outFormat
            audioConverter = outFormat.flatMap { AVAudioConverter(from: sourceFormat, to: $0) }
        }
        guard let converter = audioConverter, let outputFormat = audioOutputFormat,
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: sourceBuffer.frameCapacity + 1024) else { return }

        nonisolated(unsafe) var fed = false  // convert() calls the input block synchronously
        var conversionError: NSError?
        converter.convert(to: outBuffer, error: &conversionError) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return sourceBuffer
        }
        guard conversionError == nil, outBuffer.frameLength > 0 else { return }

        // Concatenate the per-channel planes (plane 0 then plane 1 …).
        let bufferList = UnsafeMutableAudioBufferListPointer(outBuffer.mutableAudioBufferList)
        var bytes: [UInt8] = []
        for buffer in bufferList {
            guard let base = buffer.mData else { continue }
            bytes.append(contentsOf: UnsafeBufferPointer(
                start: base.assumingMemoryBound(to: UInt8.self), count: Int(buffer.mDataByteSize)))
        }
        guard !bytes.isEmpty else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        audioContinuation.yield(SendableAudioFrame(
            sampleRate: UInt32(outputFormat.sampleRate),
            channels: UInt8(channels),
            ptsMicros: UInt64(max(0, CMTimeGetSeconds(pts)) * 1_000_000),
            data: bytes))
    }

    /// Build an `AVAudioPCMBuffer` matching `format` and copy the sample buffer's PCM into it.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("capture stopped: \(error)")
        continuation.finish()
    }
}

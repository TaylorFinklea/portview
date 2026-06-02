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

/// Captures a display with ScreenCaptureKit and exposes frames as an `AsyncStream`.
/// `.bufferingNewest(2)` drops stale frames so latency can't accumulate behind a slow encoder.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "portview.capture")
    private let audioQueue = DispatchQueue(label: "portview.capture.audio")
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

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        (frames, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(2))
        (audioFrames, audioContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
        super.init()
    }

    func start(display: SCDisplay, maxFPS: Int) throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(maxFPS))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.capturesAudio = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        self.stream = stream
        stream.startCapture { error in
            if let error { print("capture start error: \(error)") }
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

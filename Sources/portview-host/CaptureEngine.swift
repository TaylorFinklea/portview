import Foundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// A captured screen frame. `@unchecked Sendable`: ScreenCaptureKit hands us a fresh
/// pixel buffer per callback that we forward without concurrent mutation.
struct SendableFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let pts: CMTime
}

/// Captures a display with ScreenCaptureKit and exposes frames as an `AsyncStream`.
/// `.bufferingNewest(2)` drops stale frames so latency can't accumulate behind a slow encoder.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "portview.capture")
    private let continuation: AsyncStream<SendableFrame>.Continuation
    let frames: AsyncStream<SendableFrame>
    let width: Int
    let height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        (frames, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(2))
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

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        stream.startCapture { error in
            if let error { print("capture start error: \(error)") }
        }
    }

    func stop() {
        stream?.stopCapture { _ in }
        continuation.finish()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen,
              CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        continuation.yield(SendableFrame(pixelBuffer: pixelBuffer, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("capture stopped: \(error)")
        continuation.finish()
    }
}

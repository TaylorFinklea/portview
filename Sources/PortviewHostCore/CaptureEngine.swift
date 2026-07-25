// SPDX-License-Identifier: Apache-2.0
import Foundation
@preconcurrency import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreVideo
import os

private let logger = Logger(subsystem: "dev.finklea.portview", category: "capture")

/// A captured screen frame. `@unchecked Sendable`: ScreenCaptureKit hands us a fresh
/// pixel buffer per callback that we forward without concurrent mutation.
struct SendableFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let pts: CMTime
    /// The normalized crop region in effect WHEN THIS BUFFER WAS CAPTURED (not at encode time). Tagging
    /// at capture time keeps the region matched to the pixels: a buffer captured under the old crop that
    /// is encoded after a re-crop carries the OLD region, so the client never maps the zoom window into
    /// the wrong region (the "flashes wrong content on re-crop at the edge" glitch).
    let region: CGRect
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

    /// Flag a keyframe WITHOUT changing the crop — used to honor a client `.requestKeyframe` so the
    /// video pump forces the next frame to a keyframe.
    /// Gated INSIDE the actor (Sol re-review I4): the caller's `await` hop is the suspension that
    /// used to separate the serve loop's `isValid` check from this mutation, so the check has to
    /// happen here — synchronously with the write, under `perform` so a concurrent
    /// `drainInFlightEffect()` waits for it instead of returning at once.
    @discardableResult
    func requestKeyframe(gatedBy capability: SessionCapability) -> Bool {
        capability.perform { keyframeRequested = true }
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
    // Synchronously-readable copy of the applied crop region, so the capture callback can stamp each
    // buffer with the region active at production time (the actor `viewportState` can't be awaited from
    // the sync `SCStreamOutput` callback). Updated when a re-crop actually takes effect.
    private let regionLock = NSLock()
    private var appliedRegion = CGRect(x: 0, y: 0, width: 1, height: 1)
    // Guards `config`/`stream` below, written on the video task (start()) and read/mutated on the
    // serve-session task (setViewport()/stop()). TODO: replace with a full actor conversion (the
    // target end state per decisions.md) — this lock is the minimal stopgap for now.
    private let configLock = NSLock()
    // Serializes the mutate → `updateConfiguration` → rollback critical sections of `setViewport`
    // and `setMaxFPS`: both mutate the SAME shared SCStreamConfiguration reference from different
    // tasks (serve-session vs video pump), and `configLock` cannot be held across the `await`.
    // Without it, an interleaved failure rollback can restore stale fields and desync the
    // unchanged-check baseline from the live stream (the wedge the rollback exists to prevent).
    private let configUpdateGate = AsyncGate()
    /// Session authority for THIS capture (Sol re-review I4). Every privileged ScreenCaptureKit call
    /// this engine issues — `startCapture` and the live `updateConfiguration` re-crop/fps retarget —
    /// is checked against it at the OS boundary, because the serve loop's branch-level check is
    /// separated from the call by at least one suspension (`display(forID:)`, `AsyncGate.enter()`,
    /// the actor hop) and a revoke can land in that gap. Defaults to a fresh always-valid capability
    /// so non-session callers (tests of pure sizing/keyframe behavior) are unaffected.
    private let capability: SessionCapability
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

    /// Issues ONE live-stream reconfiguration to the OS. Deliberately completion-handler shaped, not
    /// `async`: the call must be *issued* synchronously inside `capability.perform`, so no suspension
    /// can separate the capability check from the privileged call (Sol re-review I4). Bound to the
    /// real `SCStream` by `start()`; a headless test installs a recorder
    /// (`installConfigurationApplierForTesting`) so that gate is exercisable without a display — the
    /// same reason `InputInjector.postEvent` is a seam.
    typealias ConfigurationApplier = (SCStreamConfiguration, @escaping @Sendable ((any Error)?) -> Void) -> Void
    private var applyConfiguration: ConfigurationApplier?

    func currentViewport() async -> CGRect { await viewportState.get() }
    func consumeKeyframeRequest() async -> Bool { await viewportState.consumeKeyframeRequest() }
    /// Force the next encoded frame to a keyframe (client `.requestKeyframe`), without a re-crop.
    /// Self-guarding (called UNWRAPPED from the serve loop, mirroring `FileReceiver`): the gate runs
    /// inside `ViewportState`, synchronously with the write, AFTER this actor hop.
    @discardableResult
    func requestKeyframe() async -> Bool { await viewportState.requestKeyframe(gatedBy: capability) }

    private func setAppliedRegion(_ rect: CGRect) {
        regionLock.lock(); appliedRegion = rect; regionLock.unlock()
    }
    private func currentAppliedRegion() -> CGRect {
        regionLock.lock(); defer { regionLock.unlock() }; return appliedRegion
    }

    private func setStreamAndConfig(_ stream: SCStream?, _ config: SCStreamConfiguration?,
                                   applier: ConfigurationApplier?) {
        configLock.lock()
        self.stream = stream
        self.config = config
        self.applyConfiguration = applier
        configLock.unlock()
    }
    private func currentStream() -> SCStream? {
        configLock.lock(); defer { configLock.unlock() }; return stream
    }
    private func currentApplierAndConfig() -> (ConfigurationApplier?, SCStreamConfiguration?) {
        configLock.lock(); defer { configLock.unlock() }; return (applyConfiguration, config)
    }

    /// Test seam (headless): install a configuration + applier without a live `SCStream`, so the
    /// capability gate wrapping the privileged reconfiguration call can be driven without a display.
    /// A test must NEVER reach the real ScreenCaptureKit surface.
    func installConfigurationApplierForTesting(_ config: SCStreamConfiguration,
                                               _ applier: @escaping ConfigurationApplier) {
        setStreamAndConfig(nil, config, applier: applier)
    }

    init(width: Int, height: Int, capability: SessionCapability = SessionCapability()) {
        self.width = width
        self.height = height
        self.capability = capability
        (frames, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(2))
        (audioFrames, audioContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
        super.init()
    }

    /// Returns `false` — with NOTHING issued to the OS — when the session capability was withdrawn
    /// before `startCapture` could be issued (Sol re-review I4). The check and the OS call are ONE
    /// synchronous critical section under `capability.perform`: `pumpVideo` reaches here only after
    /// `awaitLaneBindings()`, and the serve loop reached `startVideo` only after a registry `await`,
    /// so a branch-level check cannot cover this — a revoke landing in either gap must not be able to
    /// START screen capture for a withdrawn peer.
    @discardableResult
    func start(display: SCDisplay, maxFPS: Int) throws -> Bool {
        // Cheap early-out: an already-withdrawn session never even builds the SCStream.
        guard capability.isValid else { return false }
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
        // Authoritative gate at the OS boundary: issued under `perform`, so no suspension separates
        // the check from `startCapture` and a concurrent `drainInFlightEffect()` waits for the issue.
        return capability.perform {
            setStreamAndConfig(stream, config, applier: { configuration, completion in
                stream.updateConfiguration(configuration, completionHandler: completion)
            })
            stream.startCapture { error in
                if let error { logger.error("capture start error: \(error, privacy: .public)") }
            }
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
        // Cheap early-out only — the authoritative gate is the `perform` around the OS call below.
        guard capability.isValid else { return false }
        await configUpdateGate.enter()
        defer { configUpdateGate.leave() }
        let (applyOpt, configOpt) = currentApplierAndConfig()
        guard let apply = applyOpt, let config = configOpt else { return false }
        // Snap the captured region's SIZE to the discrete ladder (snapped up so it still covers the
        // requested window), keeping the requested center; the encoder output is sized from the SAME
        // snapped fractions, so the buffer's aspect matches the captured region exactly (no stretch)
        // while both change only at rung crossings (minimal SCStream/encoder churn). Deciding `cropping`
        // off the SNAPPED fractions (not the raw request) avoids a seam near full where a request that
        // snaps to 1.0 would otherwise take the crop path and force a redundant reconfigure.
        let snw = CaptureSizing.snapCropFraction(nw)
        let snh = CaptureSizing.snapCropFraction(nh)
        let cropping = snw < 1.0 || snh < 1.0
        let normalizedRect: CGRect
        let newRect: CGRect
        let outputSize: CaptureSizing.Size
        if cropping {
            // `.zero` (the else branch) captures the whole display at native dims.
            let ox = min(max(0, nx + nw / 2 - snw / 2), 1 - snw)
            let oy = min(max(0, ny + nh / 2 - snh / 2), 1 - snh)
            normalizedRect = CGRect(x: ox, y: oy, width: snw, height: snh)
            newRect = CGRect(x: ox * Double(width), y: oy * Double(height),
                             width: snw * Double(width), height: snh * Double(height))
            outputSize = CaptureSizing.cropOutputSize(displayWidth: width, displayHeight: height, normalizedW: snw, normalizedH: snh)
        } else {
            normalizedRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            newRect = .zero
            outputSize = CaptureSizing.Size(width: width, height: height)
        }

        let current = config.sourceRect
        let unchangedRect = abs(newRect.minX - current.minX) < 1 && abs(newRect.minY - current.minY) < 1
            && abs(newRect.width - current.width) < 1 && abs(newRect.height - current.height) < 1
        let unchangedSize = config.width == outputSize.width && config.height == outputSize.height
        if unchangedRect && unchangedSize {
            // No OS call — but the region stamp is still session state, so gate it too.
            guard capability.isValid else { return false }
            await viewportState.set(normalizedRect, requestKeyframe: false)
            setAppliedRegion(normalizedRect)
            return true
        }
        // Snapshot the last-applied state so we can roll back if the update throws — `config` is a
        // reference type whose fields double as the unchanged-check baseline, so a failed update that
        // left them mutated would desync the baseline from the live stream and could wedge the crop.
        let priorRect = config.sourceRect
        let priorWidth = config.width
        let priorHeight = config.height
        // The IRREDUCIBLE effect boundary (Sol re-review I4): the config mutation AND the issue of
        // `updateConfiguration` run inside ONE `capability.perform`, so (a) no suspension separates
        // the capability check from the privileged OS call — the `await configUpdateGate.enter()`
        // above and the serve loop's own `await`s are all upstream of it — and (b) a concurrent
        // `drainInFlightEffect()` waits for the issue instead of returning immediately. `nil` means
        // the capability was withdrawn: no field was mutated and nothing reached the OS.
        let applied: Bool? = await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            let issued = capability.perform {
                config.sourceRect = newRect
                config.width = outputSize.width
                config.height = outputSize.height
                apply(config) { error in
                    if let error { logger.error("viewport update failed: \(error, privacy: .public)") }
                    continuation.resume(returning: error == nil)
                }
            }
            if !issued { continuation.resume(returning: nil) }
        }
        guard let applied else { return false }
        guard applied else {
            config.sourceRect = priorRect
            config.width = priorWidth
            config.height = priorHeight
            return false
        }
        // Only a size change (a zoom-rung crossing) needs a forced keyframe; a pure pan moves the
        // sourceRect at the same output size, so the P-frame stream stays valid — forcing a keyframe
        // on every pan step put ~6.6 large keyframes/sec on the wire and produced a periodic hitch.
        let requestKeyframe = CaptureSizing.cropRequiresKeyframe(
            from: CaptureSizing.Size(width: priorWidth, height: priorHeight), to: outputSize)
        await viewportState.set(normalizedRect, requestKeyframe: requestKeyframe)
        // Mark the new region as applied AFTER updateConfiguration completes (Apple's signal it's in
        // effect), so buffers produced from here on are stamped with it; in-flight old-crop buffers
        // captured before this point keep the old region.
        setAppliedRegion(normalizedRect)
        return true
    }

    /// Retarget the live capture's max frame rate (the adaptive rate controller's fps output)
    /// without rebuilding the stream. Returns `true` once the new rate is in effect; a no-op
    /// change returns `true` without reconfiguring. Rolls the config field back on failure so the
    /// unchanged-check baseline stays in sync with the live stream (same rationale as
    /// `setViewport`'s rollback).
    func setMaxFPS(_ maxFPS: Int) async -> Bool {
        guard maxFPS > 0 else { return false }
        // Cheap early-out only — the authoritative gate is the `perform` around the OS call below.
        guard capability.isValid else { return false }
        await configUpdateGate.enter()
        defer { configUpdateGate.leave() }
        let (applyOpt, configOpt) = currentApplierAndConfig()
        guard let apply = applyOpt, let config = configOpt else { return false }
        let interval = CMTime(value: 1, timescale: CMTimeScale(maxFPS))
        guard config.minimumFrameInterval != interval else { return true }
        let prior = config.minimumFrameInterval
        // Same irreducible boundary as `setViewport`: mutate + issue under ONE `perform`.
        let applied: Bool? = await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            let issued = capability.perform {
                config.minimumFrameInterval = interval
                apply(config) { error in
                    if let error { logger.error("fps update failed: \(error, privacy: .public)") }
                    continuation.resume(returning: error == nil)
                }
            }
            if !issued { continuation.resume(returning: nil) }
        }
        guard let applied else { return false }
        guard applied else {
            config.minimumFrameInterval = prior
            return false
        }
        return true
    }

    func stop() {
        let stream = currentStream()
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
            continuation.yield(SendableFrame(
                pixelBuffer: pixelBuffer,
                pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                region: currentAppliedRegion()))
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
        logger.error("capture stopped: \(error, privacy: .public)")
        continuation.finish()
    }
}

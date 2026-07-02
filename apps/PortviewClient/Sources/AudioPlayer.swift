import Foundation
import AVFoundation

/// Plays the Mac's system audio: schedules incoming non-interleaved Float32 PCM frames into an
/// `AVAudioPlayerNode`. The engine is (re)configured when the stream's format first appears or changes.
@MainActor
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var running = false
    /// True from an interruption's `.began` until its `.ended` (or `stop()`): the system deactivated
    /// our session, so incoming frames are dropped instead of scheduled into a dead engine.
    private(set) var isInterrupted = false
    /// Count of interruption-ends that carried `.shouldResume` (each attempts the engine restart).
    /// Observable so tests can assert the interrupted → resumed transition without real audio.
    private(set) var interruptionResumeAttempts = 0
    private var interruptionObserver: NSObjectProtocol?

    init() {
        engine.attach(player)
        // Registered once for the player's lifetime (it spans sessions; `stop()`/`play()` cycle
        // around it) and removed in deinit. Delivered on the main queue; a main-thread post (tests)
        // arrives synchronously, a system post hops onto the actor's thread.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            let options = AVAudioSession.InterruptionOptions(
                rawValue: userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated { self?.handleInterruption(type: type, options: options) }
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    /// An interruption (call/Siri/alarm) deactivated our session: stop cleanly on `.began` so no
    /// buffers are scheduled into the dead engine, and on `.ended` + `.shouldResume` re-activate
    /// the session and restart engine + player via the existing `reconfigure` path. An `.ended`
    /// without `.shouldResume` just clears the flag — the next `play()` reconfigures on demand.
    private func handleInterruption(type: AVAudioSession.InterruptionType,
                                    options: AVAudioSession.InterruptionOptions) {
        switch type {
        case .began:
            isInterrupted = true
            player.stop()
            engine.stop()
            running = false
        case .ended:
            guard isInterrupted else { return }
            isInterrupted = false
            guard options.contains(.shouldResume) else { return }
            interruptionResumeAttempts += 1
            if let format { reconfigure(format) }
        @unknown default:
            break
        }
    }

    /// Schedule one frame of non-interleaved Float32 PCM (plane 0 then plane 1 …).
    func play(sampleRate: Double, channels: UInt32, planarData bytes: [UInt8]) {
        guard !isInterrupted else { return }  // session is the interrupter's until `.ended`
        guard channels >= 1, sampleRate > 0,
              let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: sampleRate,
                                                channels: AVAudioChannelCount(channels),
                                                interleaved: false) else { return }
        if !running || format?.sampleRate != sampleRate || format?.channelCount != AVAudioChannelCount(channels) {
            reconfigure(desiredFormat)
        }
        guard running, let buffer = Self.buffer(from: bytes, format: desiredFormat) else { return }
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    func stop() {
        player.stop()
        engine.stop()
        running = false
        format = nil
        isInterrupted = false  // deliberate teardown supersedes a pending interruption
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    private func reconfigure(_ newFormat: AVAudioFormat) {
        engine.stop()
        player.stop()
        engine.connect(player, to: engine.mainMixerNode, format: newFormat)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
            try engine.start()
            running = true
            format = newFormat
            player.play()
        } catch {
            running = false
        }
    }

    /// Rebuild an `AVAudioPCMBuffer` from contiguous per-channel Float32 planes.
    private static func buffer(from bytes: [UInt8], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let channelCount = Int(format.channelCount)
        guard channelCount > 0 else { return nil }
        let frames = AVAudioFrameCount(bytes.count / channelCount / MemoryLayout<Float>.size)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channelData = buffer.floatChannelData else { return nil }
        buffer.frameLength = frames
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for channel in 0..<channelCount {
                let plane = base.advanced(by: channel * Int(frames) * MemoryLayout<Float>.size)
                channelData[channel].update(from: plane.assumingMemoryBound(to: Float.self), count: Int(frames))
            }
        }
        return buffer
    }
}

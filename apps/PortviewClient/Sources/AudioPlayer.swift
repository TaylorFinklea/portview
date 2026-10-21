// SPDX-License-Identifier: Apache-2.0
import Foundation
import AVFoundation
import PortviewClientCore

/// Plays the Mac's system audio: schedules incoming non-interleaved Float32 PCM frames into an
/// `AVAudioPlayerNode` back-to-back on the player's own sample timeline, held within a band of each
/// frame's target present time (PTS against the audio-anchored `PresentationClock`) by
/// `AudioPlayoutScheduler`. Scheduling every frame at its own mapped host time instead slipped one
/// sample every ~2 s against the iPhone's render clock (+10.9 ppm on Roshar) — the Gate 2 audio
/// clicks. The engine is (re)configured when the stream's format first appears or changes.
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
    /// The audio-anchored A/V presentation clock: established from the FIRST scheduled frame
    /// (`offset = ptsMicros − localNow`, so that frame plays `presentationDelayMicros` in the
    /// future) and shared with the video path — `SessionViewModel` mirrors it into the renderer.
    /// Nil until audio arrives; reset by `stop()` so each session re-anchors.
    private(set) var presentationClock: PresentationClock?
    /// Places each frame on the player's sample timeline. Reset whenever the player stops (its
    /// timeline restarts); replaced when the stream's sample rate changes; dropped by `stop()`.
    private var scheduler: AudioPlayoutScheduler?
    /// Splice/resync/underrun counters for the quality HUD (device soak evidence).
    private(set) var playoutStats = AudioPlayoutStats()
    /// Last sample of each channel of the most recently scheduled buffer: a resync that lands right
    /// after it (`followsQueuedAudio`) blends from these values instead of fading in from zero. Nil
    /// whenever the player's queue was flushed.
    private var lastScheduledTail: [Float]?

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

    /// Schedule one frame of non-interleaved Float32 PCM (plane 0 then plane 1 …). The first
    /// scheduled frame anchors `presentationClock` to "now", so it plays a presentation delay in the
    /// future; later frames follow back-to-back on the player's timeline, with the scheduler
    /// splicing a few crossfaded milliseconds when they drift out of band from their target times.
    func play(sampleRate: Double, channels: UInt32, ptsMicros: UInt64, planarData bytes: [UInt8]) {
        guard !isInterrupted else { return }  // session is the interrupter's until `.ended`
        guard channels >= 1, sampleRate > 0,
              let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: sampleRate,
                                                channels: AVAudioChannelCount(channels),
                                                interleaved: false) else { return }
        if !running || format?.sampleRate != sampleRate || format?.channelCount != AVAudioChannelCount(channels) {
            reconfigure(desiredFormat)
        }
        guard running, let input = Self.planes(from: bytes, channels: Int(channels)) else { return }
        let nowMicros = Int64(ProcessInfo.processInfo.systemUptime * 1_000_000)
        let clock = presentationClock
            ?? PresentationClock(hostClockOffsetMicros: Int64(clamping: ptsMicros) - nowMicros)
        presentationClock = clock
        // Clamp to the schedule horizon (~10s past now): scheduling PCM further ahead is
        // meaningless, and a corrupt/hostile PTS after a normal anchor must not move the schedule
        // arbitrarily far out (the scheduler also clamps before any sample arithmetic).
        // On a slow route (Bluetooth) a sample is heard far later than the clock's speaker-sized budget
        // allows; schedule that much later or every buffer lands behind the committed floor and drops.
        // Bounded (≤ 10 s) and added after the clamp, so it cannot overflow.
        let session = AVAudioSession.sharedInstance()
        let routeCompensation = AudioRouteLatency.compensationMicros(
            outputLatency: session.outputLatency, ioBufferDuration: session.ioBufferDuration)
        let targetMicros = PresentationClock.clampedScheduleTargetMicros(
            clock.targetPresentTimeMicros(forPTSMicros: ptsMicros), now: nowMicros) + routeCompensation
        var scheduler = self.scheduler
            ?? AudioPlayoutScheduler(configuration: .init(sampleRate: sampleRate))
        let plan = scheduler.plan(ptsMicros: ptsMicros, frames: input.first?.count ?? 0,
                                  targetMicros: targetMicros, render: renderPosition())
        if scheduler.takeClockReanchorRequest() {
            // Arrivals are now later than the clock's budget even at the maximum audio lead
            // (sustained latency increase or accumulated clock drift): re-anchor the shared A/V
            // clock from the next frame, exactly as at session start. Video follows via the mirror.
            // No scheduler reset: the player keeps its queue, and taking the request already
            // unanchored the schedule so the next frame lands after the queued audio.
            presentationClock = nil
        }
        self.scheduler = scheduler
        playoutStats = scheduler.stats
        guard let plan else { return }
        let output = AudioSplice.apply(plan.edit, to: input,
                                       crossfadeFrames: scheduler.configuration.crossfadeFrames,
                                       joining: plan.followsQueuedAudio ? lastScheduledTail : nil)
        guard let buffer = Self.buffer(from: output, format: desiredFormat) else { return }
        lastScheduledTail = output.map { $0.last ?? 0 }
        // A sample-time-only AVAudioTime is on the player's timeline — the same timeline
        // `renderPosition()` reads — so consecutive plans abut exactly, with no host-time conversion.
        player.scheduleBuffer(buffer,
                              at: AVAudioTime(sampleTime: plan.startSample, atRate: sampleRate),
                              options: [],
                              completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    /// Where the player is now: its last render's host time (as local-uptime µs, the timeline
    /// `PresentationClock` targets use), the player-timeline sample rendered then, and the route's
    /// render cycle. Nil until the player has rendered once since it was (re)started.
    private func renderPosition() -> AudioRenderPosition? {
        guard let nodeTime = player.lastRenderTime, nodeTime.isHostTimeValid,
              let playerTime = player.playerTime(forNodeTime: nodeTime),
              playerTime.isSampleTimeValid else { return nil }
        let micros = AVAudioTime.seconds(forHostTime: nodeTime.hostTime) * 1_000_000
        return AudioRenderPosition(hostMicros: Int64(micros), sampleTime: playerTime.sampleTime,
                                   cycleFrames: renderCycleFrames(sampleRate: playerTime.sampleRate))
    }

    /// Frames the route commits per render cycle, on the player's timeline: the session's live IO
    /// buffer duration (it changes with the output route, e.g. Bluetooth) at the player's rate. Never
    /// below the 1,024 frames measured on Roshar's speaker, so an unreported or optimistic value can
    /// only make the committed floor safer, not let a buffer land in audio already rendered.
    private func renderCycleFrames(sampleRate: Double) -> Int64 {
        let ioFrames = AVAudioSession.sharedInstance().ioBufferDuration * sampleRate
        guard ioFrames.isFinite, ioFrames > 0 else { return 1_024 }
        return max(1_024, Int64(min(ioFrames.rounded(.up), 65_536)))
    }

    func stop() {
        player.stop()
        engine.stop()
        running = false
        format = nil
        isInterrupted = false  // deliberate teardown supersedes a pending interruption
        presentationClock = nil  // the next session's audio re-anchors the A/V timeline
        scheduler = nil
        playoutStats = AudioPlayoutStats()
        lastScheduledTail = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    private func reconfigure(_ newFormat: AVAudioFormat) {
        engine.stop()
        player.stop()  // flushes the queue: nothing scheduled remains to join
        lastScheduledTail = nil
        // The player's sample timeline restarts at its next `play()`: re-anchor the schedule
        // (keeping the session's counters), or start fresh if the sample rate changed.
        if scheduler?.configuration.sampleRate == newFormat.sampleRate {
            scheduler?.reset()
        } else {
            scheduler = nil
        }
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

    /// Split contiguous per-channel Float32 planes (plane 0 then plane 1 …) into one array per channel.
    private static func planes(from bytes: [UInt8], channels: Int) -> [[Float]]? {
        guard channels > 0 else { return nil }
        let frames = bytes.count / channels / MemoryLayout<Float>.size
        guard frames > 0 else { return nil }
        return bytes.withUnsafeBytes { raw in
            (0..<channels).map { channel in
                let start = channel * frames * MemoryLayout<Float>.size
                return (0..<frames).map { frame in
                    raw.loadUnaligned(fromByteOffset: start + frame * MemoryLayout<Float>.size, as: Float.self)
                }
            }
        }
    }

    /// Build an `AVAudioPCMBuffer` from one Float32 array per channel (equal lengths).
    private static func buffer(from planes: [[Float]], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = planes.first?.count ?? 0
        guard frames > 0, planes.count == Int(format.channelCount),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channelData = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        for (channel, plane) in planes.enumerated() where plane.count == frames {
            plane.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                channelData[channel].update(from: base, count: frames)
            }
        }
        return buffer
    }
}

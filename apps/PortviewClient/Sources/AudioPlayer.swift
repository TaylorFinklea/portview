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

    init() { engine.attach(player) }

    /// Schedule one frame of non-interleaved Float32 PCM (plane 0 then plane 1 …).
    func play(sampleRate: Double, channels: UInt32, planarData bytes: [UInt8]) {
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

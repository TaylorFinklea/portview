// SPDX-License-Identifier: Apache-2.0
/// Pure crossfade DSP for the splices ``AudioPlayoutScheduler`` plans.
///
/// A splice that simply cuts or duplicates samples produces a step discontinuity, which the ear
/// hears as a click — the very artifact the scheduler exists to avoid. Each splice here therefore
/// blends across a short window (`crossfadeFrames`): the outgoing signal fades out while the
/// incoming signal fades in, so the seam is continuous in value and its slope stays bounded.
///
/// Inputs and outputs are non-interleaved planes (one `[Float]` per channel, equal lengths). Each
/// channel is processed independently with identical timing, so channels stay sample-aligned.
/// Every index is clamped into range: a malformed edit degrades to a no-op or a shorter buffer
/// rather than trapping on the realtime audio path.
public enum AudioSplice {
    /// Applies `edit` to every plane and returns new planes with the same channel count.
    ///
    /// - `.none` returns the planes unchanged.
    /// - `.skip(k)` removes `k` head frames; the output is `n − k` long and the seam blends the
    ///   natural continuation (`x[i]`) into the source that now follows (`x[k + i]`).
    /// - `.repeatHead(k)` inserts `k` frames; the output is `n + k` long and the seam blends the
    ///   natural continuation (`x[k + i]`) into a replay of the head (`x[i]`).
    /// - `.resync(t)` discards the first `t` frames (already late). After silence it fades in from
    ///   zero. When `joining` carries the last sample of each channel of the buffer the player plays
    ///   immediately before this one (the plan's `followsQueuedAudio`), it instead blends from that
    ///   held sample into the new signal: fading in from zero there would step from the queued
    ///   audio's last value straight to silence, which is the click this type exists to avoid.
    ///
    /// The fade weights are `(i + 1) / (F + 1)` for the blended seams, so neither endpoint is a
    /// hard switch, and `F = min(crossfadeFrames, …)` shrinks to fit short buffers. `joining` is
    /// ignored by every edit but `.resync`, and by any channel it has no sample for.
    public static func apply(_ edit: AudioSpliceEdit, to planes: [[Float]], crossfadeFrames: Int,
                             joining previous: [Float]? = nil) -> [[Float]] {
        let fade = max(0, crossfadeFrames)
        switch edit {
        case .none:
            return planes
        case .skip(let frames):
            return planes.map { skipHead($0, frames: frames, fade: fade) }
        case .repeatHead(let frames):
            return planes.map { repeatHead($0, frames: frames, fade: fade) }
        case .resync(let trimFrames):
            return planes.enumerated().map { channel, plane in
                let held = previous.flatMap { channel < $0.count ? $0[channel] : nil }
                return resync(plane, trimFrames: trimFrames, fade: fade, joining: held)
            }
        }
    }

    /// Drops `k` head frames, blending the natural continuation into the source that follows.
    private static func skipHead(_ x: [Float], frames requested: Int, fade requestedFade: Int) -> [Float] {
        let n = x.count
        let k = min(max(requested, 0), n)
        guard k > 0 else { return x }  // a zero-length edit is an exact no-op, not a blend with itself
        let fade = min(requestedFade, n - k)
        var out = [Float](repeating: 0, count: n - k)
        for i in 0..<fade {
            let w = Float(i + 1) / Float(fade + 1)
            out[i] = x[i] * (1 - w) + x[k + i] * w
        }
        for i in fade..<(n - k) {
            out[i] = x[k + i]
        }
        return out
    }

    /// Inserts `k` frames by replaying the head, blending the natural continuation into the replay.
    private static func repeatHead(_ x: [Float], frames requested: Int, fade requestedFade: Int) -> [Float] {
        let n = x.count
        let k = min(max(requested, 0), n)
        guard k > 0 else { return x }  // a zero-length edit is an exact no-op, not a blend with itself
        let fade = min(requestedFade, n - k)
        var out = [Float](repeating: 0, count: n + k)
        for i in 0..<k {
            out[i] = x[i]
        }
        for i in 0..<fade {
            let w = Float(i + 1) / Float(fade + 1)
            out[k + i] = x[k + i] * (1 - w) + x[i] * w
        }
        for i in fade..<n {
            out[k + i] = x[i]
        }
        return out
    }

    /// Discards the first `t` frames. The remainder fades in from exact silence, or, when `held` is the
    /// last sample played just before it, blends from that held value into the new signal so the seam
    /// starts where the queued audio left off.
    private static func resync(_ x: [Float], trimFrames requested: Int, fade requestedFade: Int,
                               joining held: Float?) -> [Float] {
        let n = x.count
        let t = min(max(requested, 0), n)
        let fade = min(requestedFade, n - t)
        var out = Array(x[t...])
        if let held {
            for i in 0..<fade {
                let w = Float(i + 1) / Float(fade + 1)
                out[i] = held * (1 - w) + out[i] * w
            }
        } else {
            for i in 0..<fade {
                out[i] *= Float(i) / Float(fade)
            }
        }
        return out
    }
}

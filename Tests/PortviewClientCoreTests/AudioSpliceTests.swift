// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import PortviewClientCore

/// AudioSplice is the pure crossfade DSP behind every scheduler splice. A splice that cut or
/// duplicated samples without blending would step the waveform, and that step is the click. The
/// tests use a 440 Hz tone (amplitude 0.5, 48 kHz): its natural worst sample-to-sample step is about
/// 0.0288, so a crossfade that keeps the seams near that value is smooth, and a hard cut (about
/// 0.45 here) is unmistakable.
@Suite struct AudioSpliceTests {
    private static let sampleRate = 48_000.0
    private static let frames = 960
    private static let crossfade = 64

    /// Upper bound on any sample-to-sample step across a crossfaded seam. The spec's 0.035 is
    /// exceeded by the spec's own skip formula at its first sample: the natural step is 0.0288, and
    /// the first-sample blend `w0 · x[k]` adds `(1/65) · 0.42 ≈ 0.0065`, giving a measured 0.0353.
    /// 0.036 keeps the bound tight while staying about ten times below the hard-cut step.
    private static let seamBound: Float = 0.036

    /// The tone at (possibly negative) sample index `j`, so `tone(-1)` and `tone(n)` are the natural
    /// neighbours of a buffer.
    private static func tone(_ j: Int) -> Float {
        Float(0.5 * sin(2 * Double.pi * 440 * Double(j) / sampleRate))
    }

    private static func buffer(_ count: Int, offset: Int = 0) -> [Float] {
        (0..<count).map { tone($0 + offset) }
    }

    /// Largest absolute difference between consecutive samples.
    private static func maxStep(_ samples: [Float]) -> Float {
        zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
    }

    @Test func noneIsIdentity() {
        let planes = [Self.buffer(Self.frames), Self.buffer(Self.frames, offset: 9_000)]
        #expect(AudioSplice.apply(.none, to: planes, crossfadeFrames: Self.crossfade) == planes)
    }

    @Test func skipRemovesHeadAndKeepsBothSeamsSmooth() {
        let n = Self.frames
        let k = 37
        let x = Self.buffer(n)
        let out = AudioSplice.apply(.skip(frames: k), to: [x], crossfadeFrames: Self.crossfade)[0]

        #expect(out.count == n - k)
        // After the crossfade the output is exactly the source continuing from x[k + F].
        #expect(out[Self.crossfade..<(n - k)] == x[(k + Self.crossfade)..<n])

        // Seam check: previous buffer's last sample, the output, then the next buffer's first sample.
        let crossfaded = [Self.tone(-1)] + out + [Self.tone(n)]
        #expect(Self.maxStep(crossfaded) <= Self.seamBound)

        // Sensitivity: the same samples without a crossfade are a step far above the bound.
        let hardCut = [Self.tone(-1)] + x[k..<n] + [Self.tone(n)]
        #expect(Self.maxStep(hardCut) > 10 * Self.seamBound)
    }

    @Test func repeatHeadInsertsFramesAndKeepsBothSeamsSmooth() {
        let n = Self.frames
        let k = 37
        let x = Self.buffer(n)
        let out = AudioSplice.apply(.repeatHead(frames: k), to: [x], crossfadeFrames: Self.crossfade)[0]

        #expect(out.count == n + k)
        #expect(out[0..<k] == x[0..<k])                                          // head is untouched
        #expect(out[(k + Self.crossfade)..<(n + k)] == x[Self.crossfade..<n])    // replay resumes exactly

        let crossfaded = [Self.tone(-1)] + out + [Self.tone(n)]
        #expect(Self.maxStep(crossfaded) <= Self.seamBound)
    }

    @Test func resyncTrimsHeadAndFadesInFromSilence() {
        let n = Self.frames
        let t = 100
        let x = Self.buffer(n)
        let out = AudioSplice.apply(.resync(trimFrames: t), to: [x], crossfadeFrames: Self.crossfade)[0]

        #expect(out.count == n - t)
        #expect(out[0] == 0)  // first sample of the fade-in is exactly silent
        let fadeMatches = (0..<Self.crossfade).allSatisfy { i in
            out[i] == x[t + i] * (Float(i) / Float(Self.crossfade))
        }
        #expect(fadeMatches)
        #expect(out[Self.crossfade..<(n - t)] == x[(t + Self.crossfade)..<n])
    }

    /// A resync that lands right after queued audio blends from that audio's last sample instead of fading in
    /// from zero. The queued buffer ends on `tone(n − 1)` (about −0.48 here); the recovery's source jumps ahead.
    /// Fading in from zero would step from −0.48 straight to 0, the click. Blending from the held value keeps
    /// every step within the seam bound plus the held value's ramp, `1 / (F + 1)` of a full swing.
    @Test func resyncJoiningQueuedAudioBlendsFromItsLastSample() {
        let n = Self.frames
        let t = 100
        let previousLast = Self.tone(n - 1)
        let x = Self.buffer(n, offset: n + 137)
        let joined = AudioSplice.apply(.resync(trimFrames: t), to: [x], crossfadeFrames: Self.crossfade,
                                       joining: [previousLast])[0]
        #expect(joined.count == n - t)
        #expect(Self.maxStep([previousLast] + joined) <= Self.seamBound + 1 / Float(Self.crossfade + 1))
        #expect(joined[Self.crossfade..<(n - t)] == x[(t + Self.crossfade)..<n])

        let fadedFromZero = AudioSplice.apply(.resync(trimFrames: t), to: [x], crossfadeFrames: Self.crossfade)[0]
        #expect(Self.maxStep([previousLast] + fadedFromZero) > 10 * Self.seamBound,
                "the zero fade-in after a nonzero sample is the click this case exists to avoid")
    }

    /// `joining` only affects `.resync`, and a channel it has no sample for falls back to the fade from zero.
    @Test func joiningIsIgnoredOutsideResyncAndForMissingChannels() {
        let x = Self.buffer(Self.frames)
        let skip = AudioSplice.apply(.skip(frames: 37), to: [x], crossfadeFrames: Self.crossfade)
        #expect(AudioSplice.apply(.skip(frames: 37), to: [x], crossfadeFrames: Self.crossfade, joining: [0.4]) == skip)
        let stereo = AudioSplice.apply(.resync(trimFrames: 10), to: [x, x], crossfadeFrames: Self.crossfade,
                                       joining: [0.4])
        let faded = AudioSplice.apply(.resync(trimFrames: 10), to: [x], crossfadeFrames: Self.crossfade)[0]
        #expect(stereo[1] == faded)
        #expect(stereo[0] != faded)
    }

    @Test func channelsAreProcessedIndependently() {
        let left = Self.buffer(Self.frames)
        let right = Self.buffer(Self.frames, offset: 5_000)
        let stereo = AudioSplice.apply(.skip(frames: 37), to: [left, right], crossfadeFrames: Self.crossfade)
        #expect(stereo.count == 2)
        #expect(stereo[0] == AudioSplice.apply(.skip(frames: 37), to: [left], crossfadeFrames: Self.crossfade)[0])
        #expect(stereo[1] == AudioSplice.apply(.skip(frames: 37), to: [right], crossfadeFrames: Self.crossfade)[0])
    }

    @Test func emptyPlanesAndOversizeOrNegativeEditsDoNotCrash() {
        let empty: [[Float]] = [[], []]
        #expect(AudioSplice.apply(.skip(frames: 10), to: empty, crossfadeFrames: Self.crossfade) == empty)
        #expect(AudioSplice.apply(.repeatHead(frames: 10), to: empty, crossfadeFrames: Self.crossfade) == empty)
        #expect(AudioSplice.apply(.resync(trimFrames: 10), to: empty, crossfadeFrames: Self.crossfade) == empty)

        let x = Self.buffer(Self.frames)
        // Oversize k/t clamp to the buffer: skip everything, repeat the whole buffer, trim everything.
        #expect(AudioSplice.apply(.skip(frames: 10_000), to: [x], crossfadeFrames: Self.crossfade)[0].isEmpty)
        #expect(AudioSplice.apply(.repeatHead(frames: 10_000), to: [x], crossfadeFrames: Self.crossfade)[0] == x + x)
        #expect(AudioSplice.apply(.resync(trimFrames: 10_000), to: [x], crossfadeFrames: Self.crossfade)[0].isEmpty)
        // Negative k/t clamp to zero, which is a no-op for skip and a plain fade-in for resync.
        #expect(AudioSplice.apply(.skip(frames: -5), to: [x], crossfadeFrames: Self.crossfade)[0] == x)
        #expect(AudioSplice.apply(.resync(trimFrames: -3), to: [x], crossfadeFrames: Self.crossfade)
                == AudioSplice.apply(.resync(trimFrames: 0), to: [x], crossfadeFrames: Self.crossfade))
        // A buffer shorter than the crossfade shrinks the fade instead of indexing past the end.
        let short = Self.buffer(32)
        #expect(AudioSplice.apply(.skip(frames: 8), to: [short], crossfadeFrames: Self.crossfade)[0].count == 24)
    }
}

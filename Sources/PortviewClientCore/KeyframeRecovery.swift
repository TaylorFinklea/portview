// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Decoder-resync policy for the video stream (pure; the session view model wires it to
/// `.requestKeyframe`).
///
/// The transport's video lane coalesces to the newest two frames BY DESIGN (a stalled consumer
/// costs two frames of memory, not unbounded growth) — but HEVC delta frames reference their
/// predecessors, so one coalesced-away frame breaks the reference chain and every later delta
/// fails decode (kVTVideoDecoderBadDataErr) until a keyframe rebases it. The host answers
/// `.requestKeyframe` by forcing the next encoded frame to an IDR; this type decides WHEN the
/// client should ask (2026-07-16 device freeze: nothing ever asked — the only trigger was the
/// app-foreground hook, so one dropped frame froze the picture until the session ended).
///
/// Rules:
/// - An arriving KEYFRAME always heals the chain (it needs no history), whatever came before.
/// - A delta is clean only when it directly extends the last frame; any gap, rewind (a host
///   pump restart whose leading keyframe got dropped), or delta-with-no-keyframe-history
///   breaks the chain.
/// - A decode failure breaks the chain too (covers corrupt data with clean sequencing — e.g.
///   the healing keyframe itself failing decode).
/// - ALL request triggers — gap, decode failure, external discontinuity (app foreground) —
///   share ONE rate limiter: a broken chain re-asks at most once per `minRequestInterval`
///   (the answer is one whole keyframe, ~100s of KB — re-asking per frame would ratchet a lossy
///   link into keyframe-only streaming).
/// - `reset()` starts a fresh GENERATION (new connection, display switch): sequence numbering
///   restarts host-side per pump, so cross-generation contiguity is accidental and history is
///   void until that generation's first keyframe decodes.
///
/// `now` is a monotonic uptime (e.g. `ProcessInfo.systemUptime`), never wall-clock time.
public struct KeyframeRecovery: Sendable {
    public static let minRequestInterval: TimeInterval = 1.0

    private var lastSequence: UInt64 = 0
    private var sawKeyframe = false
    private var chainBroken = false
    private var lastRequestAt: TimeInterval = -.infinity

    public init() {}

    /// Fresh generation: call at session (re)start and on a display switch — the host's new
    /// video pump restarts sequence numbering, and its leading keyframe may itself be dropped,
    /// so an accidentally contiguous delta must not pass as clean history.
    public mutating func reset() {
        self = KeyframeRecovery()
    }

    /// Observe one arrived frame BEFORE decoding it. Returns true when a keyframe request
    /// should be sent now.
    public mutating func observeArrival(sequence: UInt64, isKeyframe: Bool, now: TimeInterval) -> Bool {
        if isKeyframe {
            sawKeyframe = true
            chainBroken = false
        } else if !sawKeyframe || sequence &- lastSequence != 1 {
            // Overflow-safe successor check: `lastSequence + 1` would trap at UInt64.max.
            chainBroken = true
        }
        lastSequence = sequence
        return requestIfDue(now: now)
    }

    /// Observe an external reason to distrust the chain (the app returned to the foreground —
    /// frames streamed past it while backgrounded). Shares the limiter with every other trigger.
    public mutating func observeDiscontinuity(now: TimeInterval) -> Bool {
        chainBroken = true
        return requestIfDue(now: now)
    }

    /// Observe a frame failing decode. Returns true when a keyframe request should be sent now.
    public mutating func observeDecodeFailure(now: TimeInterval) -> Bool {
        chainBroken = true
        return requestIfDue(now: now)
    }

    private mutating func requestIfDue(now: TimeInterval) -> Bool {
        guard chainBroken, now - lastRequestAt >= Self.minRequestInterval else { return false }
        lastRequestAt = now
        return true
    }
}

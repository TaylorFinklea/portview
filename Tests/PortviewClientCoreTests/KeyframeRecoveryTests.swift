// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import PortviewClientCore

/// Pins the client's decoder-resync policy (2026-07-16 freeze): the video lane coalesces
/// newest-2 by design, so a dropped delta BREAKS the HEVC reference chain — every later delta
/// fails kVTVideoDecoderBadDataErr until a keyframe arrives. The client must request one
/// (rate-limited) on a sequence gap or a decode failure, and treat an arriving keyframe as
/// healing regardless of history. Before this, the only trigger was the app-foreground hook —
/// one dropped frame froze the session forever.
@Suite struct KeyframeRecoveryTests {
    @Test func cleanContiguousStreamNeverRequests() {
        var recovery = KeyframeRecovery()
        #expect(recovery.observeArrival(sequence: 1, isKeyframe: true, now: 0) == false)
        for seq in UInt64(2)...60 {
            #expect(recovery.observeArrival(sequence: seq, isKeyframe: false, now: Double(seq) / 60) == false)
        }
    }

    @Test func sequenceGapRequestsOnceThenRateLimits() {
        var recovery = KeyframeRecovery()
        _ = recovery.observeArrival(sequence: 1, isKeyframe: true, now: 0)
        _ = recovery.observeArrival(sequence: 2, isKeyframe: false, now: 0.02)
        // Frames 3–11 dropped (the depth-2 lane coalesced them): first delta past the gap requests.
        #expect(recovery.observeArrival(sequence: 12, isKeyframe: false, now: 0.2) == true)
        // Chain stays broken but the request is rate-limited within the interval.
        #expect(recovery.observeArrival(sequence: 13, isKeyframe: false, now: 0.25) == false)
        #expect(recovery.observeArrival(sequence: 14, isKeyframe: false, now: 0.3) == false)
        // Still broken past the interval → allowed to ask again.
        #expect(recovery.observeArrival(sequence: 75, isKeyframe: false, now: 1.4) == true)
    }

    @Test func keyframeHealsTheChain() {
        var recovery = KeyframeRecovery()
        _ = recovery.observeArrival(sequence: 1, isKeyframe: true, now: 0)
        #expect(recovery.observeArrival(sequence: 5, isKeyframe: false, now: 0.1) == true) // gap 2–4
        // The requested keyframe lands: healed — contiguous deltas after it are clean.
        #expect(recovery.observeArrival(sequence: 20, isKeyframe: true, now: 0.4) == false)
        #expect(recovery.observeArrival(sequence: 21, isKeyframe: false, now: 0.42) == false)
    }

    @Test func decodeFailureRequestsEvenWithoutAGap() {
        var recovery = KeyframeRecovery()
        _ = recovery.observeArrival(sequence: 1, isKeyframe: true, now: 0)
        _ = recovery.observeArrival(sequence: 2, isKeyframe: false, now: 0.02)
        #expect(recovery.observeDecodeFailure(now: 0.03) == true)
        // Rate-limited within the interval, allowed after it while still failing.
        #expect(recovery.observeDecodeFailure(now: 0.5) == false)
        #expect(recovery.observeDecodeFailure(now: 1.1) == true)
    }

    @Test func failedKeyframeDecodeReBreaksTheChain() {
        var recovery = KeyframeRecovery()
        _ = recovery.observeArrival(sequence: 1, isKeyframe: true, now: 0)
        _ = recovery.observeArrival(sequence: 5, isKeyframe: false, now: 0.1) // broken
        _ = recovery.observeArrival(sequence: 20, isKeyframe: true, now: 1.2) // healing keyframe…
        #expect(recovery.observeDecodeFailure(now: 1.21) == true) // …but IT failed decode
        #expect(recovery.observeArrival(sequence: 21, isKeyframe: false, now: 1.25) == false) // rate-limited
    }

    @Test func hostPumpRestartResetsSequenceViaItsKeyframe() {
        var recovery = KeyframeRecovery()
        _ = recovery.observeArrival(sequence: 1, isKeyframe: true, now: 0)
        for seq in UInt64(2)...500 { _ = recovery.observeArrival(sequence: seq, isKeyframe: false, now: 1) }
        // Display switch: a NEW pump restarts sequence at 1 — and always leads with a keyframe.
        #expect(recovery.observeArrival(sequence: 1, isKeyframe: true, now: 2) == false)
        #expect(recovery.observeArrival(sequence: 2, isKeyframe: false, now: 2.02) == false)
    }

    @Test func deltaBeforeAnyKeyframeRequests() {
        // Joining a stream mid-flight (or the first keyframe itself was coalesced away):
        // deltas with no decodable history must ask for a keyframe.
        var recovery = KeyframeRecovery()
        #expect(recovery.observeArrival(sequence: 7, isKeyframe: false, now: 0) == true)
    }

    @Test func gapPlusDecodeFailureOnTheSameFrameRequestsOnce() {
        var recovery = KeyframeRecovery()
        _ = recovery.observeArrival(sequence: 1, isKeyframe: true, now: 0)
        var requests = 0
        if recovery.observeArrival(sequence: 12, isKeyframe: false, now: 0.2) { requests += 1 }
        if recovery.observeDecodeFailure(now: 0.2) { requests += 1 }
        #expect(requests == 1)
    }

    @Test func externalDiscontinuitySharesTheLimiter() {
        // The app-foreground hook routes through the same policy: a foreground resync followed
        // by a gap inside the interval must not double-send.
        var recovery = KeyframeRecovery()
        _ = recovery.observeArrival(sequence: 1, isKeyframe: true, now: 0)
        #expect(recovery.observeDiscontinuity(now: 5) == true)
        #expect(recovery.observeArrival(sequence: 60, isKeyframe: false, now: 5.3) == false)
        #expect(recovery.observeArrival(sequence: 61, isKeyframe: false, now: 6.1) == true)
    }

    @Test func resetStartsAFreshGeneration() {
        // Display switch / reconnect: a NEW pump restarts sequence — and its leading keyframe
        // can itself be dropped. After reset, an ACCIDENTALLY contiguous delta (new seq happens
        // to extend the old chain) must still be treated as history-less and request.
        var recovery = KeyframeRecovery()
        _ = recovery.observeArrival(sequence: 1, isKeyframe: true, now: 0)
        _ = recovery.observeArrival(sequence: 2, isKeyframe: false, now: 0.02)
        recovery.reset()
        #expect(recovery.observeArrival(sequence: 3, isKeyframe: false, now: 0.1) == true)
    }

    @Test func sequenceAtUInt64MaxDoesNotTrap() {
        var recovery = KeyframeRecovery()
        _ = recovery.observeArrival(sequence: .max, isKeyframe: true, now: 0)
        _ = recovery.observeArrival(sequence: .max, isKeyframe: false, now: 0.1)
        _ = recovery.observeDecodeFailure(now: 0.2)
    }

    @Test func backwardsDeltaSequenceIsBroken() {
        // A delta with a LOWER sequence than the last seen (pump restarted but its keyframe
        // was dropped) is a broken chain, not a rewind to ignore.
        var recovery = KeyframeRecovery()
        _ = recovery.observeArrival(sequence: 1, isKeyframe: true, now: 0)
        for seq in UInt64(2)...100 { _ = recovery.observeArrival(sequence: seq, isKeyframe: false, now: 0.5) }
        #expect(recovery.observeArrival(sequence: 2, isKeyframe: false, now: 2) == true)
    }
}

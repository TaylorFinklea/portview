// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import PortviewHostCore

/// `SessionCapability` (han.4 Task 1): a per-session act-permission flag gating whether a session
/// may still perform effects. Withdrawal is TWO operations over TWO locks (Sol review C1), and the
/// flag deliberately DOES flip while an effect is mid-flight:
///
/// - `markInvalid()` takes only `flagLock`, so it returns — and `isValid` reads false — with an
///   effect still parked inside `perform`. That is what lets a batch teardown withdraw every
///   sibling's authority before waiting on any one of them.
/// - `drainInFlightEffect()` takes `effectLock`, so IT is the half that cannot return until the
///   in-flight effect finishes. `invalidate()` is mark-then-drain, so it blocks too — but its mark
///   has already landed by then.
/// - `perform` re-checks the flag UNDER `effectLock`, which is what bounds the residual to at most
///   ONE effect: a caller that queued behind an in-flight effect observes the mark on acquiring the
///   lock and never runs its own effect.
@Suite struct SessionCapabilityTests {
    /// Lock-guarded flag box for observing state mutated from a background thread (mirrors the
    /// `Counter`/`Overlap` idiom in InputInjectorGateTests/AsyncGateTests).
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
        var current: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test func invalidateFlipsIsValid() {
        let capability = SessionCapability()
        #expect(capability.isValid == true)
        capability.invalidate()
        #expect(capability.isValid == false)
    }

    @Test func performRunsIffValid() {
        let capability = SessionCapability()
        var ran = false
        let result = capability.perform { ran = true }
        #expect(ran == true)
        #expect(result == true)

        capability.invalidate()
        var ranAfterInvalidate = false
        let resultAfterInvalidate = capability.perform { ranAfterInvalidate = true }
        #expect(ranAfterInvalidate == false)
        #expect(resultAfterInvalidate == false)
    }

    /// `invalidate()` is mark-then-drain: its MARK lands immediately (observably — `isValid` reads
    /// false while the effect is still parked), and its DRAIN is what cannot return until that effect
    /// finishes. The effect itself is never torn: `perform` holds `effectLock` for its whole duration,
    /// so the already-running effect completes — that is the ≤ one-effect residual, not an exclusion.
    @Test func invalidateMarksAtOnceButItsDrainCannotReturnMidEffect() {
        let capability = SessionCapability()
        // The effect parks here until the test releases it, so `perform` is guaranteed to be
        // holding the effect lock (mid-effect) when `invalidate()` is fired on another thread.
        let enteredEffect = DispatchSemaphore(value: 0)
        let releaseEffect = DispatchSemaphore(value: 0)
        let effectRan = Flag()
        let performResult = Flag()
        let invalidateCompleted = Flag()
        let group = DispatchGroup()

        // Dedicated `Thread`s (not the shared GCD global-queue pool) so thread creation itself
        // can't stall behind unrelated work when the full parallel test suite is saturating the
        // GCD worker pool.
        group.enter()
        Thread.detachNewThread {
            let result = capability.perform {
                effectRan.set(true)
                enteredEffect.signal()
                releaseEffect.wait()
            }
            performResult.set(result)
            group.leave()
        }

        // Wait for perform() to have actually acquired the lock and parked inside the effect
        // before racing invalidate() against it. Bound generous enough to stay reliable under a
        // fully-loaded parallel `swift test` run, not just in isolation.
        #expect(enteredEffect.wait(timeout: .now() + 10) == .success)

        group.enter()
        Thread.detachNewThread {
            capability.invalidate()
            invalidateCompleted.set(true)
            group.leave()
        }

        // Bounded window for invalidate() to mark and then block in its drain. The MARK is already
        // visible (`isValid` takes only `flagLock`, which no effect ever holds — reading it here does
        // NOT deadlock), while invalidate() itself has NOT returned: its drain is queued on the
        // effect lock the parked effect holds.
        Thread.sleep(forTimeInterval: 0.05)
        #expect(capability.isValid == false)
        #expect(invalidateCompleted.current == false)

        releaseEffect.signal()
        #expect(group.wait(timeout: .now() + 10) == .success)

        // The in-flight effect ran to completion and `perform` returned true — the flag flipping
        // under it does not tear it — and only THEN could invalidate's drain return.
        #expect(effectRan.current == true)
        #expect(performResult.current == true)
        #expect(invalidateCompleted.current == true)
        #expect(capability.isValid == false)
    }

    /// Sol review C1: `markInvalid()` is the NON-blocking half. It takes only the flag lock, so it
    /// returns — and the flag is observably false — while an effect is still parked mid-flight. This
    /// is what lets a batch teardown withdraw EVERY session's authority before waiting on any one of
    /// them; the fused single-lock `invalidate()` could not (it blocked on the first stalled effect).
    @Test func markInvalidReturnsWhileAnEffectIsStillInFlight() {
        let capability = SessionCapability()
        let enteredEffect = DispatchSemaphore(value: 0)
        let releaseEffect = DispatchSemaphore(value: 0)
        let performDone = DispatchSemaphore(value: 0)

        Thread.detachNewThread {
            capability.perform { enteredEffect.signal(); releaseEffect.wait() }
            performDone.signal()
        }
        #expect(enteredEffect.wait(timeout: .now() + 10) == .success)

        // Both of these run on the TEST thread while the effect is parked — neither may block.
        capability.markInvalid()
        #expect(capability.isValid == false)

        releaseEffect.signal()
        #expect(performDone.wait(timeout: .now() + 10) == .success)
    }

    /// The blocking half: `drainInFlightEffect()` returns only once the in-flight effect is done.
    @Test func drainWaitsOutTheInFlightEffect() {
        let capability = SessionCapability()
        let enteredEffect = DispatchSemaphore(value: 0)
        let releaseEffect = DispatchSemaphore(value: 0)
        let drainReturned = DispatchSemaphore(value: 0)

        Thread.detachNewThread { capability.perform { enteredEffect.signal(); releaseEffect.wait() } }
        #expect(enteredEffect.wait(timeout: .now() + 10) == .success)

        capability.markInvalid()
        Thread.detachNewThread { capability.drainInFlightEffect(); drainReturned.signal() }
        #expect(drainReturned.wait(timeout: .now() + 0.05) == .timedOut)

        releaseEffect.signal()
        #expect(drainReturned.wait(timeout: .now() + 10) == .success)
    }

    /// The residual a non-blocking mark accepts is **at most one** effect per capability, and that
    /// bound is enforced by `perform`'s re-check UNDER the effect lock: a second caller that queued
    /// behind the in-flight effect sees the mark when it finally acquires the lock, and its effect
    /// never runs.
    ///
    /// The barrier sits at the ACTUAL post-fast-path / pre-effect-lock point (Sol pass 3), via the
    /// internal `setWillAcquireEffectLockForTesting` seam. The earlier version signalled `atGate`
    /// immediately *before* calling `perform` and then inferred lock acquisition from two 200 ms
    /// timeouts — a second thread descheduled after `atGate` until after the mark would reject at the
    /// fast path and still satisfy every assertion, so the test passed with the under-lock re-check
    /// deleted. Parking the second caller inside the seam makes the interleaving exact rather than
    /// inferred:
    ///   1. The seam fires only after the fast-path `isValid` check has already PASSED, so the mark
    ///      that follows cannot be the thing that rejected this caller.
    ///   2. The caller is released into `effectLock.lock()` only after the mark, and the lock is held
    ///      by the parked first effect, so it necessarily queues there and observes the mark on
    ///      acquiring it.
    /// The `false` it returns therefore can only have come from the re-check under the lock.
    @Test func aSecondEffectQueuedBehindAnInFlightOneIsRejectedByTheUnderLockRecheck() {
        let capability = SessionCapability()
        let enteredFirst = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let atGate = DispatchSemaphore(value: 0)
        let releaseGate = DispatchSemaphore(value: 0)
        let secondDone = DispatchSemaphore(value: 0)
        let secondRan = Flag()
        let secondResult = Flag()

        Thread.detachNewThread { capability.perform { enteredFirst.signal(); releaseFirst.wait() } }
        #expect(enteredFirst.wait(timeout: .now() + 10) == .success)

        // Installed only now, so it can fire for the SECOND caller and not the parked first one.
        capability.setWillAcquireEffectLockForTesting { atGate.signal(); releaseGate.wait() }
        Thread.detachNewThread {
            let result = capability.perform { secondRan.set(true) }
            secondResult.set(result)
            secondDone.signal()
        }
        // Past the fast path — with the capability still valid, so it was NOT rejected there.
        #expect(atGate.wait(timeout: .now() + 10) == .success)
        #expect(capability.isValid == true)

        capability.markInvalid()
        releaseGate.signal()          // now it proceeds into `effectLock.lock()` and queues
        #expect(secondDone.wait(timeout: .now() + 0.2) == .timedOut)

        releaseFirst.signal()
        #expect(secondDone.wait(timeout: .now() + 10) == .success)
        #expect(secondRan.current == false)
        #expect(secondResult.current == false)
    }

}

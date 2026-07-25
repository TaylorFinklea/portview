// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import PortviewHostCore

/// `SessionCapability` (han.4 Task 1): a per-session act-permission flag gating whether a session
/// may still perform effects. `perform` and `invalidate` share ONE lock so a concurrent invalidate
/// can never interleave with an in-flight perform — either the effect runs to completion under the
/// lock and THEN invalidate flips it, or invalidate wins the lock first and perform never runs its
/// effect at all. No torn interleave (the flag flipping WHILE an effect is mid-flight) is possible.
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

    @Test func performAndInvalidateAreMutuallyExclusive() {
        let capability = SessionCapability()
        // The effect parks here until the test releases it, so `perform` is guaranteed to be
        // holding the lock (mid-effect) when `invalidate()` is fired on another thread.
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

        // Bounded window for invalidate() to reach (and block on) the shared lock. It must NOT
        // have completed yet — proof invalidate() cannot return while perform()'s effect is still
        // in flight, i.e. the flag never flips mid-effect. (Deliberately does not read
        // `capability.isValid` here: that getter takes the SAME lock the parked effect is holding,
        // so calling it before releasing the effect would deadlock this thread too.)
        Thread.sleep(forTimeInterval: 0.05)
        #expect(invalidateCompleted.current == false)

        releaseEffect.signal()
        #expect(group.wait(timeout: .now() + 10) == .success)

        // Exactly one ordering: perform ran its effect to completion (and returned true) THEN
        // invalidate flipped the flag.
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
    /// never runs. (Robust either way — a caller that had not yet passed the fast-path check is
    /// rejected there instead; neither path may run the effect.)
    @Test func aSecondEffectQueuedBehindAnInFlightOneIsRejectedAfterTheMark() {
        let capability = SessionCapability()
        let enteredFirst = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondDone = DispatchSemaphore(value: 0)
        let secondRan = Flag()
        let secondResult = Flag()

        Thread.detachNewThread { capability.perform { enteredFirst.signal(); releaseFirst.wait() } }
        #expect(enteredFirst.wait(timeout: .now() + 10) == .success)

        Thread.detachNewThread {
            let result = capability.perform { secondRan.set(true) }
            secondResult.set(result)
            secondDone.signal()
        }
        Thread.sleep(forTimeInterval: 0.05)  // let the second caller reach the effect lock
        capability.markInvalid()
        releaseFirst.signal()

        #expect(secondDone.wait(timeout: .now() + 10) == .success)
        #expect(secondRan.current == false)
        #expect(secondResult.current == false)
    }
}

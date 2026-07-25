// SPDX-License-Identifier: Apache-2.0
import Foundation
import ScreenCaptureKit
import Testing
@testable import PortviewHostCore

@Suite struct CaptureEngineTests {
    /// Lock-guarded counters/flags for state mutated from a background thread (mirrors the
    /// `Counter`/`Flag` idiom in `InputInjectorGateTests`/`SessionCapabilityTests`).
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
        func increment() { lock.lock(); _count += 1; lock.unlock() }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
        var current: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test func concurrentSetViewportCallsWithoutStartReturnWithoutCrashing() async {
        // No start() call, so `config`/the configuration applier are never assigned — this exercises
        // the configLock-guarded reads from many tasks at once and asserts they all return cleanly
        // (no crash, no deadlock) rather than any particular viewport outcome.
        let engine = CaptureEngine(width: 1920, height: 1080)

        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<200 {
                let nx = Double(i % 10) / 10
                group.addTask {
                    await engine.setViewport(normalizedX: nx, normalizedY: 0, normalizedW: 0.5, normalizedH: 0.5)
                }
            }
            var results: [Bool] = []
            for await result in group {
                results.append(result)
            }
            #expect(results.count == 200)
            #expect(results.allSatisfy { $0 == false })
        }
    }

    @Test func requestKeyframeIsHonoredAndConsumedExactlyOnce() async {
        // Routes a client `.requestKeyframe` wire message: set the keyframe flag without a re-crop,
        // then the video pump consumes it once to force the next frame to a keyframe.
        let engine = CaptureEngine(width: 1920, height: 1080)
        #expect(await engine.consumeKeyframeRequest() == false)
        #expect(await engine.requestKeyframe())
        #expect(await engine.consumeKeyframeRequest() == true)
        #expect(await engine.consumeKeyframeRequest() == false)
    }

    // MARK: - Sol re-review I4: the gate is at the OS boundary, not at the serve-loop branch

    /// The I4 interleaving for the magnifier: `.viewport` passed the serve loop's branch-level
    /// `isValid` check, the revoke landed, and the closure then resumed past `setViewport`'s
    /// `AsyncGate.enter()` suspension and applied a **revoked peer's crop** to the live
    /// `SCStreamConfiguration`. The gate now lives at the irreducible boundary — the config mutation
    /// and the issue of `updateConfiguration` run inside ONE `capability.perform` — so a mark that
    /// lands anywhere after the branch check stops the privileged call.
    ///
    /// Driven through the `installConfigurationApplierForTesting` seam: a test must NEVER reach the
    /// real ScreenCaptureKit surface (no live `SCStream`, no display).
    ///
    /// The mark lands BETWEEN the gate's check and its effect (Sol pass 3), via the internal
    /// `setWillAcquireEffectLockForTesting` seam. Marking before *calling* `setViewport` — the earlier
    /// version — only exercised the cheap early return at the top of the method, so the test stayed
    /// green with the authoritative inner `capability.perform` deleted; here `setViewport` runs its own
    /// fast-path check against a still-valid capability and the withdrawal arrives afterwards, so only
    /// the boundary gate can stop the OS call.
    @Test func aRevokeLandingAfterTheServeLoopCheckStopsTheLiveRecropAtTheOSBoundary() async {
        let capability = SessionCapability()
        let engine = CaptureEngine(width: 1920, height: 1080, capability: capability)
        let configuration = SCStreamConfiguration()
        let issuedToOS = Counter()
        engine.installConfigurationApplierForTesting(configuration) { _, completion in
            issuedToOS.increment()
            completion(nil)
        }

        // Positive control: while the capability is valid the crop really is issued.
        #expect(await engine.setViewport(normalizedX: 0.25, normalizedY: 0.25,
                                         normalizedW: 0.5, normalizedH: 0.5))
        #expect(issuedToOS.count == 1)
        let appliedRect = configuration.sourceRect
        let appliedWidth = configuration.width
        let appliedHeight = configuration.height

        // The serve loop's branch check AND `setViewport`'s own early-out both pass — the revoke lands
        // only once the call is already past them, in the window before the effect lock.
        #expect(capability.isValid)
        capability.setWillAcquireEffectLockForTesting { capability.markInvalid() }
        // … and the effect must be refused at the OS boundary, not merely at the branch.
        #expect(await engine.setViewport(normalizedX: 0.6, normalizedY: 0.6,
                                         normalizedW: 0.25, normalizedH: 0.25) == false)
        #expect(issuedToOS.count == 1)                      // no second updateConfiguration was issued
        #expect(configuration.sourceRect == appliedRect)    // and no config field was mutated either
        #expect(configuration.width == appliedWidth)
        #expect(configuration.height == appliedHeight)
    }

    /// Sol pass 3, N3 (I4 residual): a re-crop that lands inside the `< 1`-pixel tolerance must
    /// perform NO state writes at all. The old form still hopped into `viewportState` to re-stamp the
    /// region after a bare `isValid` check that holds no effect lock, so a revoke landing in that hop
    /// mutated session state after withdrawal — and because the tolerance admits a sub-pixel-different
    /// rect, those writes were not even idempotent: the frame stamp drifted away from the
    /// configuration ScreenCaptureKit is actually running.
    @Test func aToleranceQualifiedNoOpRecropWritesNoSessionStateAtAll() async {
        let engine = CaptureEngine(width: 1920, height: 1080)
        let issuedToOS = Counter()
        engine.installConfigurationApplierForTesting(SCStreamConfiguration()) { _, completion in
            issuedToOS.increment()
            completion(nil)
        }

        #expect(await engine.setViewport(normalizedX: 0.25, normalizedY: 0.25,
                                         normalizedW: 0.5, normalizedH: 0.5))
        #expect(issuedToOS.count == 1)
        let applied = await engine.currentViewport()

        // 0.0004 of a 1920-px display is 0.768 px — inside the tolerance, so no reconfiguration is
        // needed, but a DIFFERENT normalized rect from the one actually applied.
        #expect(await engine.setViewport(normalizedX: 0.2504, normalizedY: 0.25,
                                         normalizedW: 0.5, normalizedH: 0.5))
        #expect(issuedToOS.count == 1)                       // still a no-op at the OS
        #expect(await engine.currentViewport() == applied)   // …and at the session state too
    }

    /// The other half of I4: the old branch-level check held **no lock**, so a concurrent
    /// `drainInFlightEffect()` returned at once while a privileged reconfiguration was still in
    /// flight — `beginRevoke` could return believing the residual was waited out. Coupled to
    /// `perform`, the drain cannot return until the issued call's critical section ends.
    @Test func drainWaitsForAnInFlightLiveRecropInsteadOfReturningAtOnce() {
        let capability = SessionCapability()
        let engine = CaptureEngine(width: 1920, height: 1080, capability: capability)
        let enteredApplier = DispatchSemaphore(value: 0)
        let releaseApplier = DispatchSemaphore(value: 0)
        let drainReturned = DispatchSemaphore(value: 0)
        let recropDone = DispatchSemaphore(value: 0)
        let recropResult = Flag()

        engine.installConfigurationApplierForTesting(SCStreamConfiguration()) { _, completion in
            enteredApplier.signal()
            releaseApplier.wait()
            completion(nil)
        }

        Task.detached {
            recropResult.set(await engine.setViewport(normalizedX: 0, normalizedY: 0,
                                                      normalizedW: 0.5, normalizedH: 0.5))
            recropDone.signal()
        }
        // The reconfiguration is now parked INSIDE `perform`, i.e. inside the capability's effect lock.
        #expect(enteredApplier.wait(timeout: .now() + 10) == .success)

        capability.markInvalid()
        Thread.detachNewThread { capability.drainInFlightEffect(); drainReturned.signal() }
        #expect(drainReturned.wait(timeout: .now() + 0.2) == .timedOut)

        releaseApplier.signal()
        #expect(drainReturned.wait(timeout: .now() + 10) == .success)
        #expect(recropDone.wait(timeout: .now() + 10) == .success)
        #expect(recropResult.current == true)   // the already-issued call still completed (the ≤1 residual)
    }

    /// Same interleaving for the actor-isolated keyframe request: the branch check passed, the revoke
    /// landed, and the closure resumed past the `ViewportState` hop and flagged a keyframe for a
    /// withdrawn peer. The gate now runs INSIDE the actor, synchronously with the write.
    @Test func aRevokeLandingAfterTheServeLoopCheckStopsTheKeyframeRequest() async {
        let capability = SessionCapability()
        let engine = CaptureEngine(width: 1920, height: 1080, capability: capability)

        #expect(await engine.requestKeyframe())                 // positive control
        #expect(await engine.consumeKeyframeRequest() == true)

        #expect(capability.isValid)                             // the branch check passes …
        capability.markInvalid()                                // … the revoke lands in the gap …
        #expect(await engine.requestKeyframe() == false)        // … the actor-side gate refuses it
        #expect(await engine.consumeKeyframeRequest() == false)
    }

    /// Stronger form of the above: the mark lands while the request is ALREADY past the actor hop and
    /// past the fast-path check, waiting to acquire the capability's effect lock — an interleaving no
    /// pre-hop `isValid` check can catch by construction.
    ///
    /// The barrier is the internal `setWillAcquireEffectLockForTesting` seam (Sol pass 3), not a
    /// signal fired immediately before the call: the earlier version signalled `atGate` from the task
    /// *before* `requestKeyframe()` and inferred the rest from a 200 ms timeout, so a task descheduled
    /// until after the mark would reject at the fast path and still satisfy every assertion — the
    /// under-lock re-check was never required.
    @Test func aKeyframeRequestQueuedOnTheEffectLockIsRefusedByTheUnderLockRecheck() {
        let capability = SessionCapability()
        let engine = CaptureEngine(width: 1920, height: 1080, capability: capability)
        let parked = DispatchSemaphore(value: 0)
        let releaseParked = DispatchSemaphore(value: 0)
        let atGate = DispatchSemaphore(value: 0)
        let releaseGate = DispatchSemaphore(value: 0)
        let requestDone = DispatchSemaphore(value: 0)
        let granted = Flag()

        // Occupy the capability's effect lock, so the gate inside the actor must queue behind it.
        Thread.detachNewThread { capability.perform { parked.signal(); releaseParked.wait() } }
        #expect(parked.wait(timeout: .now() + 10) == .success)

        // Installed after the parked effect is inside, so it fires only for the keyframe request.
        capability.setWillAcquireEffectLockForTesting { atGate.signal(); releaseGate.wait() }
        Task.detached {
            granted.set(await engine.requestKeyframe())
            requestDone.signal()
        }
        // Past the actor hop AND past the fast-path check, with the capability still valid — so the
        // rejection that follows cannot be the fast path's.
        #expect(atGate.wait(timeout: .now() + 10) == .success)
        #expect(capability.isValid)

        capability.markInvalid()
        releaseGate.signal()          // proceeds into `effectLock.lock()`, behind the parked effect
        #expect(requestDone.wait(timeout: .now() + 0.2) == .timedOut)

        releaseParked.signal()
        #expect(requestDone.wait(timeout: .now() + 10) == .success)
        #expect(granted.current == false)
    }
}

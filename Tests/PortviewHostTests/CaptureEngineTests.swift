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

        // The serve loop's branch-level check passes HERE …
        #expect(capability.isValid)
        // … the revoke lands during the suspension that follows it …
        capability.markInvalid()
        // … and the effect must be refused at the OS boundary, not merely at the branch.
        #expect(await engine.setViewport(normalizedX: 0.6, normalizedY: 0.6,
                                         normalizedW: 0.25, normalizedH: 0.25) == false)
        #expect(issuedToOS.count == 1)                      // no second updateConfiguration was issued
        #expect(configuration.sourceRect == appliedRect)    // and no config field was mutated either
        #expect(configuration.width == appliedWidth)
        #expect(configuration.height == appliedHeight)
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
    /// queued on the capability's effect lock — an interleaving that a pre-hop `isValid` check cannot
    /// catch by construction. The discriminator is that the request **cannot complete** while another
    /// effect is parked: a pre-hop-only gate would have seen a still-valid capability, set the flag
    /// and returned immediately.
    @Test func aKeyframeRequestQueuedOnTheEffectLockIsRefusedByTheUnderLockRecheck() {
        let capability = SessionCapability()
        let engine = CaptureEngine(width: 1920, height: 1080, capability: capability)
        let parked = DispatchSemaphore(value: 0)
        let releaseParked = DispatchSemaphore(value: 0)
        let atGate = DispatchSemaphore(value: 0)
        let requestDone = DispatchSemaphore(value: 0)
        let granted = Flag()

        // Occupy the capability's effect lock, so the gate inside the actor must queue behind it.
        Thread.detachNewThread { capability.perform { parked.signal(); releaseParked.wait() } }
        #expect(parked.wait(timeout: .now() + 10) == .success)

        Task.detached {
            atGate.signal()
            granted.set(await engine.requestKeyframe())
            requestDone.signal()
        }
        #expect(atGate.wait(timeout: .now() + 10) == .success)
        // Still VALID here, so the request cannot have been rejected — and it cannot have run (the
        // effect lock is held). Non-completion therefore means it is queued on that lock, past the hop.
        #expect(requestDone.wait(timeout: .now() + 0.2) == .timedOut)

        capability.markInvalid()
        releaseParked.signal()
        #expect(requestDone.wait(timeout: .now() + 10) == .success)
        #expect(granted.current == false)
    }
}

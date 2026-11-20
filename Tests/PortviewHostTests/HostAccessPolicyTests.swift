// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
@testable import PortviewHostCore

@Suite(.timeLimit(.minutes(1))) struct HostAccessPolicyTests {
    @Test func secureDefaultsDenySensitiveEffects() {
        let policy = HostAccessPolicy()
        #expect(!policy.clipboardEnabled)
        #expect(!policy.fileTransferEnabled)
    }

    @Test func disablingIsVisibleSynchronously() {
        let policy = HostAccessPolicy(clipboardEnabled: true, fileTransferEnabled: true)
        policy.update(clipboardEnabled: false, fileTransferEnabled: false)
        #expect(!policy.clipboardEnabled)
        #expect(!policy.fileTransferEnabled)
    }

    @Test func performRunsOnlyWhileEnabled() {
        let policy = HostAccessPolicy()
        var ran = false
        #expect(policy.perform(.clipboard) { ran = true } == nil)
        #expect(!ran)
        policy.update(clipboardEnabled: true, fileTransferEnabled: false)
        #expect(policy.perform(.clipboard) { ran = true } != nil)
        #expect(ran)
        #expect(policy.perform(.fileTransfer) { 1 } == nil)
    }

    @Test func disableGenerationBumpsOnlyOnEnabledToDisabled() {
        let policy = HostAccessPolicy()
        #expect(policy.disableGeneration(.fileTransfer) == 0)
        policy.update(clipboardEnabled: false, fileTransferEnabled: true)   // enable: no bump
        #expect(policy.disableGeneration(.fileTransfer) == 0)
        policy.update(clipboardEnabled: false, fileTransferEnabled: true)   // no change: no bump
        #expect(policy.disableGeneration(.fileTransfer) == 0)
        policy.update(clipboardEnabled: false, fileTransferEnabled: false)  // disable: bump
        #expect(policy.disableGeneration(.fileTransfer) == 1)
        #expect(policy.disableGeneration(.clipboard) == 0)                  // other feature untouched
        policy.update(clipboardEnabled: false, fileTransferEnabled: false)  // still off: no bump
        #expect(policy.disableGeneration(.fileTransfer) == 1)
    }

    @Test func permitsRejectsAfterADisableEvenIfReEnabled() {
        let policy = HostAccessPolicy(fileTransferEnabled: true)
        let gen = policy.disableGeneration(.fileTransfer)
        #expect(policy.permits(.fileTransfer, sinceGeneration: gen))
        policy.update(clipboardEnabled: false, fileTransferEnabled: false)
        policy.update(clipboardEnabled: false, fileTransferEnabled: true)
        #expect(policy.fileTransferEnabled)
        #expect(!policy.permits(.fileTransfer, sinceGeneration: gen))
    }

    /// Deterministic: the effect is parked inside `perform`; `update(disable)` must not return until
    /// the effect finishes.
    @Test func updateDisableWaitsOutAnInFlightEffect() {
        let policy = HostAccessPolicy(clipboardEnabled: true)
        let inEffect = DispatchSemaphore(value: 0)
        let releaseEffect = DispatchSemaphore(value: 0)
        let updateReturned = DispatchSemaphore(value: 0)
        let finished = FlagBox()

        Thread.detachNewThread {
            policy.perform(.clipboard) {
                inEffect.signal()
                releaseEffect.wait()
                finished.set()
            }
        }
        #expect(inEffect.wait(timeout: .now() + 5) == .success)

        Thread.detachNewThread {
            policy.update(clipboardEnabled: false, fileTransferEnabled: false)
            updateReturned.signal()
        }
        // The update is blocked behind the parked effect.
        #expect(updateReturned.wait(timeout: .now() + 0.3) == .timedOut)
        #expect(!finished.value)

        releaseEffect.signal()
        #expect(updateReturned.wait(timeout: .now() + 5) == .success)
        #expect(finished.value)          // update returned only AFTER the effect finished
        #expect(!policy.clipboardEnabled)
    }
}

final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

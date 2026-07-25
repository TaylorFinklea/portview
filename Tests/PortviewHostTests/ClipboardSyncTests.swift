// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
@preconcurrency import AppKit
@testable import PortviewHostCore

/// `ClipboardSync.applyRemote` (han.4 Task 5, design §4/§7 invariant 2 + §8 "Clipboard MainActor
/// recheck"): the single pasteboard mutation is deferred onto a `Task { @MainActor }`, so a guard
/// at `applyRemote`'s call site would be too early — `capability.perform` rechecks validity INSIDE
/// that deferred task, at the instant the mutation would actually run, so a write queued before
/// invalidation still drops (finding 3 / H-d), whether invalidation came from a revoke or a normal
/// teardown.
@Suite struct ClipboardSyncTests {
    /// Fake pasteboard so these tests never touch the real system pasteboard (mirrors
    /// `InputInjector.postEvent`'s stubbing rationale — a live `NSPasteboard` write is a real,
    /// observable side effect on the dev machine).
    private final class FakePasteboard: ClipboardPasteboard, @unchecked Sendable {
        private let lock = NSLock()
        private var _changeCount = 0
        private var _string: String?

        var changeCount: Int { lock.lock(); defer { lock.unlock() }; return _changeCount }

        @discardableResult
        func clearContents() -> Int {
            lock.lock(); defer { lock.unlock() }
            _string = nil
            _changeCount += 1
            return _changeCount
        }

        @discardableResult
        func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
            lock.lock(); defer { lock.unlock() }
            _string = string
            _changeCount += 1
            return true
        }

        func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
            lock.lock(); defer { lock.unlock() }
            return _string
        }
    }

    @Test func validCapabilityAppliesTheDeferredWrite() async {
        let pasteboard = FakePasteboard()
        let sync = ClipboardSync(pasteboard: pasteboard, capability: SessionCapability())

        sync.applyRemote("hello")

        for _ in 0..<500 {
            if pasteboard.string(forType: .string) == "hello" { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(pasteboard.string(forType: .string) == "hello")
    }

    @Test func invalidatedBeforeApplyRemoteDropsTheDeferredWrite() async {
        let pasteboard = FakePasteboard()
        let capability = SessionCapability()
        capability.invalidate()
        let sync = ClipboardSync(pasteboard: pasteboard, capability: capability)

        sync.applyRemote("must not land")

        // Absence assertion: a short fixed grace period is fine here (mirrors
        // OutboundLaneTests.finishStopsDeliveryIncludingPendingAndLaterEnqueues) — it can only
        // false-pass on a slow machine, never false-fail.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test func invalidatedAfterNormalTeardownDropsAnAlreadyQueuedWrite() async {
        // Mirrors a NORMAL disconnect, not a revoke: teardown's Invalidate-Capability-First
        // invariant (H-d) invalidates before any deferred effect can outlive it. `invalidate()` is
        // synchronous and completes (NSLock-guarded) before this function proceeds, so by the time
        // the deferred MainActor task eventually runs `capability.perform`, the capability is
        // ALREADY invalid — deterministic, not a race against the Task's scheduling.
        let pasteboard = FakePasteboard()
        let capability = SessionCapability()
        let sync = ClipboardSync(pasteboard: pasteboard, capability: capability)

        sync.applyRemote("queued before teardown")
        capability.invalidate()

        try? await Task.sleep(for: .milliseconds(200))
        #expect(pasteboard.string(forType: .string) == nil)
    }
}

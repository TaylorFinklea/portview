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
        private var _reads = 0

        var changeCount: Int { lock.lock(); defer { lock.unlock() }; _reads += 1; return _changeCount }

        /// Number of `changeCount` + `string(forType:)` reads — what a disabled policy must keep at 0.
        var reads: Int { lock.lock(); defer { lock.unlock() }; return _reads }

        /// A local copy by the Mac user (not counted as a read).
        func copyLocally(_ string: String) {
            lock.lock(); defer { lock.unlock() }
            _string = string
            _changeCount += 1
        }

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
            _reads += 1
            return _string
        }
    }

    private func enabledPolicy() -> HostAccessPolicy {
        HostAccessPolicy(clipboardEnabled: true, fileTransferEnabled: true)
    }

    private final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func disabledPollingNeverReadsThePasteboardNorSends() async {
        let pasteboard = FakePasteboard()
        pasteboard.copyLocally("secret")
        let sent = Sent()
        let sync = ClipboardSync(pasteboard: pasteboard, capability: SessionCapability(),
                                 policy: HostAccessPolicy(), pollInterval: .milliseconds(5))
        sync.start { sent.add($0) }
        try? await Task.sleep(for: .milliseconds(200))
        sync.stop()
        #expect(pasteboard.reads == 0)
        #expect(sent.all.isEmpty)
    }

    @Test func disabledRemoteClipboardNeverWritesThePasteboard() async {
        let pasteboard = FakePasteboard()
        let sync = ClipboardSync(pasteboard: pasteboard, capability: SessionCapability(), policy: HostAccessPolicy())
        sync.applyRemote("must not land")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(pasteboard.string(forType: .string) == nil)
        #expect(pasteboard.changeCount == 0)
    }

    @Test func disablingAfterStartStopsLaterReadsAndSends() async {
        let pasteboard = FakePasteboard()
        let policy = enabledPolicy()
        let sent = Sent()
        let sync = ClipboardSync(pasteboard: pasteboard, capability: SessionCapability(),
                                 policy: policy, pollInterval: .milliseconds(5))
        sync.start { sent.add($0) }
        try? await Task.sleep(for: .milliseconds(30))
        pasteboard.copyLocally("first")
        #expect(await eventually { sent.all == ["first"] })

        policy.update(clipboardEnabled: false, fileTransferEnabled: true)
        let readsAtDisable = pasteboard.reads
        pasteboard.copyLocally("while disabled")
        try? await Task.sleep(for: .milliseconds(200))
        sync.stop()
        #expect(pasteboard.reads == readsAtDisable)
        #expect(sent.all == ["first"])
    }

    @Test func copyMadeWhileDisabledIsNotSentAfterReEnable() async {
        let pasteboard = FakePasteboard()
        let policy = enabledPolicy()
        let sent = Sent()
        let sync = ClipboardSync(pasteboard: pasteboard, capability: SessionCapability(),
                                 policy: policy, pollInterval: .milliseconds(5))
        sync.start { sent.add($0) }
        policy.update(clipboardEnabled: false, fileTransferEnabled: true)
        try? await Task.sleep(for: .milliseconds(50))
        pasteboard.copyLocally("old secret")
        policy.update(clipboardEnabled: true, fileTransferEnabled: true)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(sent.all.isEmpty)          // re-baselined on the first enabled tick
        pasteboard.copyLocally("fresh")
        #expect(await eventually { sent.all == ["fresh"] })
        sync.stop()
    }

    @Test func validCapabilityAppliesTheDeferredWrite() async {
        let pasteboard = FakePasteboard()
        let sync = ClipboardSync(pasteboard: pasteboard, capability: SessionCapability(), policy: enabledPolicy())

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
        let sync = ClipboardSync(pasteboard: pasteboard, capability: capability, policy: enabledPolicy())

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
        let sync = ClipboardSync(pasteboard: pasteboard, capability: capability, policy: enabledPolicy())

        sync.applyRemote("queued before teardown")
        capability.invalidate()

        try? await Task.sleep(for: .milliseconds(200))
        #expect(pasteboard.string(forType: .string) == nil)
    }
}

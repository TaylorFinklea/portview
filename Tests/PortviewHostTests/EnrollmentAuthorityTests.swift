// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import PortviewHostCore
import PortviewProtocol

/// `EnrollmentAuthority` (han.3 design v2, must-fixes 1 + 5): the host-local single-request-per-
/// window ceremony state machine the enrollment prompt runs on. Load-bearing invariants pinned
/// here: at most one attempt pending at a time; exact-attempt approve/deny (stale/unknown UUID is
/// a no-op); deny/timeout/windowClosed block the source for the window (approve does not); the
/// per-window request cap; windowOpened() as a hard epoch reset; and — the security-critical bit —
/// that every resolution path (approve, deny, the internal deadline, windowClosed) races safely
/// against `awaitDecision` with no double-resume and no leaked continuation.
@Suite struct EnrollmentAuthorityTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Runs one attempt to resolution via `deny`, so callers can cheaply free the pending slot
    /// (and, incidentally, block `source`) without caring about the returned value.
    private func denyAndDrain(_ authority: EnrollmentAuthority, _ attemptID: UUID) async {
        async let result = authority.awaitDecision(attemptID)
        await authority.deny(attemptID)
        _ = await result
    }

    @Test func beginCapturesSnapshotAndFingerprint() async throws {
        let authority = EnrollmentAuthority()
        var keyBytes = Data([0x01, 0x02, 0x03, 0x04])
        let request = try #require(await authority.begin(
            publicKey: keyBytes, claimedName: "Taylor's iPhone", source: "10.0.0.5", now: now))

        // Mutate the caller's copy AFTER begin — the request must be unaffected (Data value/COW
        // semantics; no defensive copy needed, but pin the behavior directly rather than assume it).
        keyBytes.append(0xFF)

        #expect(request.publicKey == Data([0x01, 0x02, 0x03, 0x04]))
        #expect(request.fingerprint == KeyFingerprint.short(forPublicKey: Data([0x01, 0x02, 0x03, 0x04])))
        #expect(request.claimedName == "Taylor's iPhone")
        #expect(request.source == "10.0.0.5")
        #expect(request.createdAt == now)
        #expect(request.expiresAt == now.addingTimeInterval(25))
    }

    @Test func expiresAtDerivesFromInjectedDeadline() async throws {
        // expiresAt must be derived from the injected `deadline`, not a hardcoded constant —
        // otherwise they can silently diverge (a caller injecting a custom deadline would still
        // see a request advertised as expiring at now+25s).
        let authority = EnrollmentAuthority(deadline: .milliseconds(2500))
        let request = try #require(await authority.begin(
            publicKey: Data([1]), claimedName: "A", source: "s1", now: now))
        #expect(request.expiresAt == now.addingTimeInterval(2.5))
    }

    @Test func secondBeginWhilePendingIsNil() async throws {
        let authority = EnrollmentAuthority()
        _ = try #require(await authority.begin(
            publicKey: Data([1]), claimedName: "A", source: "s1", now: now))
        let second = await authority.begin(
            publicKey: Data([2]), claimedName: "B", source: "s2", now: now)
        #expect(second == nil)
    }

    @Test func beginAfterResolutionWorks() async throws {
        let authority = EnrollmentAuthority()
        let first = try #require(await authority.begin(
            publicKey: Data([1]), claimedName: "A", source: "s1", now: now))
        async let firstResult = authority.awaitDecision(first.attemptID)
        await authority.approve(first.attemptID)
        #expect(await firstResult == true)

        // Same source as the just-approved attempt — approve must NOT block it (unlike deny).
        let second = await authority.begin(
            publicKey: Data([2]), claimedName: "B", source: "s1", now: now)
        #expect(second != nil)
    }

    @Test func approveExactAttemptReturnsTrue() async throws {
        let authority = EnrollmentAuthority()
        let request = try #require(await authority.begin(
            publicKey: Data([1]), claimedName: "A", source: "s1", now: now))
        // Concurrent: approve() may run before OR after awaitDecision actually parks its
        // continuation — the actor's "decided" carryover must make either ordering resolve true.
        async let result = authority.awaitDecision(request.attemptID)
        await authority.approve(request.attemptID)
        #expect(await result == true)
    }

    @Test func approveWrongUUIDIsNoOp() async throws {
        let authority = EnrollmentAuthority(deadline: .milliseconds(80))
        let request = try #require(await authority.begin(
            publicKey: Data([1]), claimedName: "A", source: "s1", now: now))
        async let result = authority.awaitDecision(request.attemptID)
        await authority.approve(UUID())
        // Wrong UUID was a no-op; the real attempt still resolves false at the deadline.
        #expect(await result == false)
    }

    @Test func denyBlocksSourceForWindow() async throws {
        let authority = EnrollmentAuthority()
        let request = try #require(await authority.begin(
            publicKey: Data([1]), claimedName: "A", source: "s1", now: now))
        await denyAndDrain(authority, request.attemptID)

        let sameSource = await authority.begin(
            publicKey: Data([2]), claimedName: "B", source: "s1", now: now)
        #expect(sameSource == nil)

        let otherSource = await authority.begin(
            publicKey: Data([3]), claimedName: "C", source: "s2", now: now)
        #expect(otherSource != nil)
    }

    @Test func deadlineBlocksSourceAndResolvesFalse() async throws {
        let authority = EnrollmentAuthority(deadline: .milliseconds(80))
        let request = try #require(await authority.begin(
            publicKey: Data([1]), claimedName: "A", source: "s1", now: now))
        let resolved = await authority.awaitDecision(request.attemptID)
        #expect(resolved == false)

        let sameSource = await authority.begin(
            publicKey: Data([2]), claimedName: "B", source: "s1", now: now)
        #expect(sameSource == nil)
    }

    @Test func windowClosedInvalidatesPendingAndBlocks() async throws {
        let authority = EnrollmentAuthority()
        let request = try #require(await authority.begin(
            publicKey: Data([1]), claimedName: "A", source: "s1", now: now))
        async let result = authority.awaitDecision(request.attemptID)
        await authority.windowClosed()
        #expect(await result == false)

        // Window stays closed until the next windowOpened() — begin() is nil for every source,
        // which subsumes (and cannot, via the public surface, be disentangled from) the specific
        // per-source block windowClosed() also records; see self-review notes in the task report.
        #expect(await authority.begin(
            publicKey: Data([2]), claimedName: "B", source: "s1", now: now) == nil)
        #expect(await authority.begin(
            publicKey: Data([3]), claimedName: "C", source: "s2", now: now) == nil)
    }

    @Test func windowClosedInvalidatesPreParkApproval() async throws {
        // A decision recorded BEFORE any `awaitDecision` ever parks (i.e. `pending.decided` was
        // set by `approve` racing ahead) is deliberately discarded by a window-epoch change —
        // fail-safe direction only. This pins that `invalidatePending` is unconditional even over
        // an already-`true` decision, per spec must-fix 5 ("deny/timeout/close invalidates it").
        let authority = EnrollmentAuthority()
        let request = try #require(await authority.begin(
            publicKey: Data([1]), claimedName: "A", source: "s1", now: now))
        await authority.approve(request.attemptID)
        await authority.windowClosed()
        #expect(await authority.awaitDecision(request.attemptID) == false)
    }

    @Test func windowOpenedResetsBlocksCapAndStalePending() async throws {
        let authority = EnrollmentAuthority(deadline: .milliseconds(80))

        // Block one source via deny.
        let blockedAttempt = try #require(await authority.begin(
            publicKey: Data([1]), claimedName: "A", source: "blocked-src", now: now))
        await denyAndDrain(authority, blockedAttempt.attemptID)
        #expect(await authority.begin(
            publicKey: Data([9]), claimedName: "X", source: "blocked-src", now: now) == nil)

        // Consume 3 more of the shared per-window cap (4 used so far).
        for i in 0..<3 {
            let r = try #require(await authority.begin(
                publicKey: Data([UInt8(i + 2)]), claimedName: "C\(i)", source: "cap-src-\(i)", now: now))
            await denyAndDrain(authority, r.attemptID)
        }

        // 5th (final cap slot) is left pending/unresolved on purpose, to prove windowOpened()
        // clears a stale pending attempt.
        let stale = try #require(await authority.begin(
            publicKey: Data([77]), claimedName: "Stale", source: "stale-src", now: now))
        async let staleResult = authority.awaitDecision(stale.attemptID)

        // Cap now exhausted (5/5) — a 6th begin (fresh, unblocked source) is nil.
        #expect(await authority.begin(
            publicKey: Data([88]), claimedName: "Over", source: "fresh-src", now: now) == nil)

        await authority.windowOpened()

        // Stale pending resolved false by the epoch reset.
        #expect(await staleResult == false)

        // Blocked source usable again (blocks reset), each resolved so the next begin isn't
        // rejected by "a request is pending".
        let reopened = try #require(await authority.begin(
            publicKey: Data([9]), claimedName: "X", source: "blocked-src", now: now))
        await denyAndDrain(authority, reopened.attemptID)

        // Cap reset: the reopened-source begin above already used 1 of 5 post-reset slots; 4 more
        // fresh begins succeed (5 total), then a 6th is nil again.
        for i in 0..<4 {
            let r = try #require(await authority.begin(
                publicKey: Data([UInt8(100 + i)]), claimedName: "Fresh\(i)", source: "post-src-\(i)", now: now))
            await denyAndDrain(authority, r.attemptID)
        }
        #expect(await authority.begin(
            publicKey: Data([199]), claimedName: "Over2", source: "post-src-over", now: now) == nil)
    }

    @Test func requestCapPerWindow() async throws {
        let authority = EnrollmentAuthority()
        for i in 0..<5 {
            let r = try #require(await authority.begin(
                publicKey: Data([UInt8(i)]), claimedName: "N\(i)", source: "src-\(i)", now: now))
            await denyAndDrain(authority, r.attemptID)
        }
        let sixth = await authority.begin(
            publicKey: Data([99]), claimedName: "Sixth", source: "src-6", now: now)
        #expect(sixth == nil)

        await authority.windowOpened()
        let afterReset = await authority.begin(
            publicKey: Data([100]), claimedName: "Reset", source: "src-reset", now: now)
        #expect(afterReset != nil)
    }

    @Test func cancellationResolvesFalseWithoutBlockingSource() async throws {
        let authority = EnrollmentAuthority()
        let request = try #require(await authority.begin(
            publicKey: Data([1]), claimedName: "A", source: "s1", now: now))

        let waiter = Task<Bool, Never> {
            await authority.awaitDecision(request.attemptID)
        }
        // Give the task a chance to actually park its continuation before cancelling it —
        // cancellation is a host-side event (e.g. the serve task tearing down), not peer
        // misbehavior, so unlike deny/timeout/windowClosed it must NOT block the source.
        try await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        #expect(await waiter.value == false)

        let sameSource = await authority.begin(
            publicKey: Data([2]), claimedName: "B", source: "s1", now: now)
        #expect(sameSource != nil)
    }

    @Test func doubleParkSameAttemptGuardsAgainstLeak() async throws {
        // One-caller-per-attempt contract: a second concurrent `awaitDecision` for the SAME
        // attemptID must not steal/overwrite the first caller's already-parked continuation
        // (that would leak it forever — the first caller would never resume). Force a
        // deterministic ordering (park first, then a beat later attempt to park again) rather
        // than racing two `async let`s, so the assertions below aren't ambiguous about which
        // call "won".
        let authority = EnrollmentAuthority(deadline: .milliseconds(150))
        let request = try #require(await authority.begin(
            publicKey: Data([1]), claimedName: "A", source: "s1", now: now))

        async let firstResult = authority.awaitDecision(request.attemptID)
        try await Task.sleep(for: .milliseconds(30))
        let secondResult = await authority.awaitDecision(request.attemptID)

        // The new (second) caller gets an immediate `false` from the defensive guard.
        #expect(secondResult == false)
        // The original park is untouched and still resolves on its own (here, at the deadline)
        // — proof its continuation was never stolen/leaked.
        #expect(await firstResult == false)
    }

    @Test func singleResume() async throws {
        // approve, then deny (no-op), then let the background deadline timer fire harmlessly —
        // if any resolver double-resumed the parked CheckedContinuation, this crashes the process
        // (a `CheckedContinuation` traps on double-resume), which is exactly the invariant this
        // test exists to pin down.
        let authority = EnrollmentAuthority(deadline: .milliseconds(80))
        let request = try #require(await authority.begin(
            publicKey: Data([1]), claimedName: "A", source: "s1", now: now))
        async let result = authority.awaitDecision(request.attemptID)
        await authority.approve(request.attemptID)
        await authority.deny(request.attemptID)
        #expect(await result == true)

        try await Task.sleep(for: .milliseconds(150))
    }
}

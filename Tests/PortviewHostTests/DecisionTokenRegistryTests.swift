// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
@testable import PortviewHostCore

/// Per-attempt enrollment-decision bookkeeping (§6b): a second Allow/Deny start for an attempt
/// already authenticating is rejected (never launching a second LAContext), each task's `defer`
/// clears only its OWN token (a stale task can't clear a newer one for the same attempt), and
/// `hasApprovalInFlight` distinguishes an in-flight Allow from an in-flight Deny.
///
/// `beginIfIdle` is a `mutating` method, so its calls are made OUTSIDE the `#expect`/`#require`
/// macros (which treat their receiver as immutable) and the returned token asserted separately.
@Suite struct DecisionTokenRegistryTests {
    let attempt = UUID()

    @Test func beginIfIdleReturnsTokenWhenIdle() {
        var r = DecisionTokenRegistry()
        #expect(!r.isInFlight(attempt))
        let token = r.beginIfIdle(attemptID: attempt, isApproval: true)
        #expect(token != nil)
        #expect(r.isInFlight(attempt))
    }

    @Test func secondBeginForInFlightAttemptIsRejected() {
        var r = DecisionTokenRegistry()
        let first = r.beginIfIdle(attemptID: attempt, isApproval: true)
        let second = r.beginIfIdle(attemptID: attempt, isApproval: true)
        #expect(first != nil)
        #expect(second == nil)   // no second LAContext while the first decision is in flight
    }

    @Test func staleTokenClearIsANoOpButMatchingTokenClears() throws {
        var r = DecisionTokenRegistry()
        let staleResult = r.beginIfIdle(attemptID: attempt, isApproval: true)
        let stale = try #require(staleResult)
        r.clear(attemptID: attempt, ifToken: stale)   // owns the entry → clears it
        #expect(!r.isInFlight(attempt))
        // A newer decision for the SAME attemptID takes the slot; the stale task's defer must not
        // clear this newer token.
        let newerResult = r.beginIfIdle(attemptID: attempt, isApproval: false)
        let newer = try #require(newerResult)
        r.clear(attemptID: attempt, ifToken: stale)   // stale token — no-op, newer entry survives
        #expect(r.isInFlight(attempt))
        r.clear(attemptID: attempt, ifToken: newer)   // matching token — clears
        #expect(!r.isInFlight(attempt))
    }

    @Test func hasApprovalInFlightReflectsIsApproval() {
        var r = DecisionTokenRegistry()
        let denyAttempt = UUID()
        let approvalToken = r.beginIfIdle(attemptID: attempt, isApproval: true)
        let denyToken = r.beginIfIdle(attemptID: denyAttempt, isApproval: false)
        #expect(approvalToken != nil)
        #expect(denyToken != nil)
        #expect(r.hasApprovalInFlight(attempt))          // an Allow is authenticating
        #expect(!r.hasApprovalInFlight(denyAttempt))     // a Deny is authenticating, not an approval
        #expect(r.isInFlight(denyAttempt))               // …but it IS in flight
        #expect(!r.hasApprovalInFlight(UUID()))          // unknown attempt: nothing in flight
    }

    @Test func unconditionalClearRemovesTheEntry() {
        // The resolution handler narrows its correlated-clear to the resolved attemptID without
        // holding its token — this by-attempt clear removes whatever token is there.
        var r = DecisionTokenRegistry()
        let token = r.beginIfIdle(attemptID: attempt, isApproval: true)
        #expect(token != nil)
        r.clear(attemptID: attempt)
        #expect(!r.isInFlight(attempt))
        #expect(!r.hasApprovalInFlight(attempt))
    }
}

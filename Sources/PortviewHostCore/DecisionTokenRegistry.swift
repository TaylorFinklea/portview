// SPDX-License-Identifier: Apache-2.0
import Foundation

/// One in-flight enrollment decision's opaque, per-task identity. Minted fresh (a new `id`) by
/// `DecisionTokenRegistry.beginIfIdle` — its `init` is internal so only the registry mints them —
/// and captured by the launching task so its `defer` can clear ONLY its own token (a stale task must
/// never clear a newer decision for the same attempt). `isApproval` distinguishes an Allow tap
/// (LAContext gating enrollment) from a Deny tap, so the UI can tell "an approval is authenticating"
/// from "a denial is authenticating".
public struct DecisionToken: Equatable, Sendable {
    public let id: UUID
    public let isApproval: Bool
    init(id: UUID, isApproval: Bool) {
        self.id = id
        self.isApproval = isApproval
    }
}

/// Pure, value-type bookkeeping for the host's per-attempt enrollment decisions (mirrors
/// `SASAttemptLimiter`: unit-tested directly, with the @MainActor/LAContext UI as a thin shell).
/// Keyed by enrollment `attemptID`, it holds at most one in-flight `DecisionToken` per attempt so a
/// second Allow/Deny tap for an attempt already authenticating is REJECTED (never launching a second
/// LAContext), while distinct attempts stay independent (no global flag leaking one prompt's
/// in-flight state onto another's buttons).
public struct DecisionTokenRegistry: Sendable {
    private var tokens: [UUID: DecisionToken] = [:]

    public init() {}

    /// Start a decision for `attemptID` iff none is already in flight for it: returns a fresh token
    /// (stored) when idle, or nil to REJECT a duplicate start (the caller must not launch a second
    /// LAContext). `isApproval` records whether this is an Allow (true) or Deny (false).
    public mutating func beginIfIdle(attemptID: UUID, isApproval: Bool) -> DecisionToken? {
        guard tokens[attemptID] == nil else { return nil }
        let token = DecisionToken(id: UUID(), isApproval: isApproval)
        tokens[attemptID] = token
        return token
    }

    /// Clear the entry for `attemptID` ONLY if it still holds `ifToken` — a stale task's `defer` must
    /// not clear a newer token that a later `beginIfIdle` minted for the same attemptID.
    public mutating func clear(attemptID: UUID, ifToken: DecisionToken) {
        guard tokens[attemptID] == ifToken else { return }
        tokens[attemptID] = nil
    }

    /// Clear the entry for `attemptID` regardless of which token holds it. Used by the resolution
    /// handler, which narrows the correlated-clear to the resolved attemptID but does not hold its
    /// token; safe because attemptIDs are unique, so there is never a different attempt under this id.
    public mutating func clear(attemptID: UUID) {
        tokens[attemptID] = nil
    }

    /// True while any decision (Allow or Deny) is authenticating for `attemptID` — gates that
    /// prompt's buttons so a double-tap can't launch a second LAContext.
    public func isInFlight(_ attemptID: UUID) -> Bool {
        tokens[attemptID] != nil
    }

    /// True while an APPROVAL (Allow tap) is authenticating for `attemptID` — used to surface the
    /// "expired before approval completed" message exactly once.
    public func hasApprovalInFlight(_ attemptID: UUID) -> Bool {
        tokens[attemptID]?.isApproval == true
    }
}

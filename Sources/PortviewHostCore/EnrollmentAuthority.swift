// SPDX-License-Identifier: Apache-2.0
import Foundation
import PortviewProtocol

/// One in-flight enrollment attempt (han.3 design v2): an unknown-but-validly-signed key asking to
/// be enrolled while the pairing window is open. `publicKey` is the exact snapshot captured at
/// `begin` time — never re-read from the caller's (mutable) copy — and is intentionally NOT exposed
/// beyond this module (this whole type is module-internal; key-material hygiene).
struct EnrollmentRequest: Equatable, Sendable {
    let attemptID: UUID
    let publicKey: Data
    let fingerprint: String
    let claimedName: String
    let source: String
    let createdAt: Date
    let expiresAt: Date
}

/// Single-request-per-window ceremony state machine (must-fixes 1, 5 — design v2). At most ONE
/// enrollment attempt is pending at a time; it resolves EXACTLY ONCE — via `approve`, `deny`, the
/// internal 25 s deadline, `windowClosed()`, or the awaiting task's cancellation — and every one of
/// those paths is safe to race against every other because all mutation happens inside this actor's
/// isolation with no `await` between reading `pending` and deciding what to do with it. Deny, the
/// deadline, and `windowClosed()` additionally block the request's source for the remainder of the
/// window (must-fix 5: without this, a denied/timed-out attacker could re-prompt-grind); `approve`
/// deliberately does NOT block, since the source just succeeded. `windowOpened()` is the fresh-epoch
/// reset: it clears blocks, the request cap, and invalidates (resolves false) any stale pending
/// attempt left over from a prior window.
public actor EnrollmentAuthority {
    /// A pending attempt as tracked by the actor. `continuation` is nil until `awaitDecision` parks
    /// it; `decided` is set when a resolution (approve/deny/timeout/etc.) races AHEAD of the parking
    /// call — `awaitDecision` then delivers it immediately instead of suspending. This lets every
    /// resolution path run as a plain, synchronous, actor-isolated mutation regardless of whether
    /// the corresponding `awaitDecision` call has reached its `withCheckedContinuation` yet.
    private struct PendingAttempt {
        let request: EnrollmentRequest
        var continuation: CheckedContinuation<Bool, Never>?
        var decided: Bool?
    }

    /// Finding GLM1 (adversarial review — slot-occupation DoS): must satisfy
    /// `requestCapPerWindow * deadline < SASAttemptLimiter.windowDuration` (120s default) by
    /// construction, or an attacker serializing `requestCapPerWindow` parked attempts can occupy
    /// the single enrollment slot for the ENTIRE pairing window, starving the legit device.
    /// 4 * 25s = 100s < 120s.
    private static let requestCapPerWindow = 4

    private var pending: PendingAttempt?
    private var blockedSources: Set<String> = []
    /// Finding H (adversarial review): deny/timeout/windowClosed block the presented KEY too, not
    /// just the network source — a source alone lets an attacker re-prompt-grind the SAME key by
    /// simply rotating address (IPv4/IPv6). `begin()` refuses a blocked key regardless of source.
    private var blockedKeys: Set<Data> = []
    private var requestsThisWindow = 0
    private var windowOpen = true
    private let deadline: Duration
    private let now: () -> Date

    public init(deadline: Duration = .seconds(25), now: @escaping () -> Date = Date.init) {
        self.deadline = deadline
        self.now = now
    }

    /// `Duration` -> `TimeInterval` so `expiresAt` can be derived directly from the injected
    /// `deadline` instead of a separately-hardcoded constant (they must never diverge).
    private static func timeInterval(for duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }

    /// Admits a new attempt, or returns nil if: one is already pending, `source` OR `publicKey` is
    /// blocked for this window (Finding H), the window's request cap is exhausted, or
    /// `windowClosed()` was the last window event received. Captures `publicKey` as an independent
    /// snapshot (Swift `Data` value/COW semantics: the caller mutating its own copy afterward never
    /// touches this one).
    func begin(publicKey: Data, claimedName: String, source: String, now: Date) -> EnrollmentRequest? {
        guard windowOpen else { return nil }
        guard pending == nil else { return nil }
        guard !blockedSources.contains(source) else { return nil }
        guard !blockedKeys.contains(publicKey) else { return nil }
        guard requestsThisWindow < Self.requestCapPerWindow else { return nil }
        let request = EnrollmentRequest(
            attemptID: UUID(),
            publicKey: publicKey,
            fingerprint: KeyFingerprint.short(forPublicKey: publicKey),
            claimedName: claimedName,
            source: source,
            createdAt: now,
            expiresAt: now.addingTimeInterval(Self.timeInterval(for: deadline)))
        requestsThisWindow += 1
        pending = PendingAttempt(request: request, continuation: nil, decided: nil)
        return request
    }

    /// Parks until `attemptID` resolves (or returns false immediately for a stale/unknown ID — the
    /// attempt already settled, or was never the one currently pending). Spawns the deadline racer
    /// only once actually parked; on fire it calls `timeout(attemptID)`, which — like every other
    /// resolution path — is a no-op unless it still owns the pending attempt, giving single-resume
    /// by construction (mirrors `HostRunner.MessageReader`'s `SingleResumeGate` race, generalized to
    /// more than two competing resolvers via actor isolation instead of a separate gate object).
    func awaitDecision(_ attemptID: UUID) async -> Bool {
        guard let existing = pending, existing.request.attemptID == attemptID else { return false }
        if let decided = existing.decided {
            pending = nil
            return decided
        }
        let waitDuration = deadline
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                guard var entry = pending, entry.request.attemptID == attemptID else {
                    continuation.resume(returning: false)
                    return
                }
                if let decided = entry.decided {
                    pending = nil
                    continuation.resume(returning: decided)
                    return
                }
                // One-caller-per-attempt contract: if another `awaitDecision` for this same
                // attemptID already parked a continuation, don't steal/overwrite it — that would
                // leak the first caller's continuation forever. Resolve this new, redundant
                // caller immediately instead.
                guard entry.continuation == nil else {
                    continuation.resume(returning: false)
                    return
                }
                entry.continuation = continuation
                pending = entry
                Task {
                    try? await Task.sleep(for: waitDuration)
                    self.timeout(attemptID)
                }
            }
        } onCancel: {
            Task { await self.cancelled(attemptID) }
        }
    }

    /// Exact-attempt approval; a stale/unknown `attemptID` (no longer — or never — the pending one)
    /// is a no-op. Does not block the source. `expiresAt` is authoritative here (Finding D,
    /// adversarial review): the 25 s deadline is otherwise enforced only by a relative
    /// `Task.sleep` racer inside `awaitDecision`, and a late-firing timer plus a late `approve()`
    /// could otherwise enroll past the advertised deadline. Checked against the injected `now`
    /// clock so it's a pure, testable comparison rather than trusting the timer to have already
    /// fired — an approve at or past `expiresAt` is treated exactly like a timeout (resolves false,
    /// blocks the source) instead of enrolling.
    public func approve(_ attemptID: UUID) {
        if let entry = pending, entry.request.attemptID == attemptID, entry.decided == nil,
           now() >= entry.request.expiresAt {
            resolve(attemptID, outcome: false, blockSource: true)
            return
        }
        resolve(attemptID, outcome: true, blockSource: false)
    }

    /// Exact-attempt denial; a stale/unknown `attemptID` is a no-op. Blocks the source for the
    /// remainder of the window (must-fix 5).
    public func deny(_ attemptID: UUID) {
        resolve(attemptID, outcome: false, blockSource: true)
    }

    /// Fresh window epoch: resets blocked sources AND blocked keys (Finding H), and the request
    /// cap, and invalidates (resolves false, without blocking) any stale pending attempt left over
    /// from before this call.
    public func windowOpened() {
        windowOpen = true
        blockedSources.removeAll()
        blockedKeys.removeAll()
        requestsThisWindow = 0
        invalidatePending(blockSource: false)
    }

    /// Window closed: no further `begin()` succeeds until the next `windowOpened()`. Invalidates any
    /// pending attempt (resolves false) and blocks its source for this window.
    public func windowClosed() {
        windowOpen = false
        invalidatePending(blockSource: true)
    }

    /// Internal 25 s (or injected `deadline`) timeout for a parked `awaitDecision`. Blocks the
    /// source (must-fix 5 — documented as load-bearing against re-prompt grinding).
    private func timeout(_ attemptID: UUID) {
        resolve(attemptID, outcome: false, blockSource: true)
    }

    /// The awaiting task was cancelled (e.g. the serve task tearing down, connection death
    /// unwinding via the caller's `withTaskCancellationHandler`) — resolve false so the
    /// continuation isn't leaked, but do NOT block the source: cancellation is a host-side event,
    /// not peer misbehavior, so it must not carry the same re-prompt-grinding penalty as
    /// deny/timeout/windowClosed.
    private func cancelled(_ attemptID: UUID) {
        resolve(attemptID, outcome: false, blockSource: false)
    }

    /// Shared resolution path for approve/deny/timeout/cancellation: only acts if `attemptID` is
    /// still THE pending attempt AND it has not already been decided by an earlier resolver
    /// (guarantees single-resume — every other resolver for the same or a stale ID, or one that
    /// merely lost the race to decide first, becomes a no-op). Delivers immediately if a
    /// continuation is already parked; otherwise records the decision for `awaitDecision` to pick
    /// up the moment it parks (or finds it already decided, per its own pre-check).
    private func resolve(_ attemptID: UUID, outcome: Bool, blockSource: Bool) {
        guard var entry = pending, entry.request.attemptID == attemptID, entry.decided == nil else { return }
        if blockSource {
            blockedSources.insert(entry.request.source)
            // Finding H: block the presented KEY too, not just the source — otherwise an attacker
            // rotating source (IPv4/IPv6) with the SAME key just re-prompts.
            blockedKeys.insert(entry.request.publicKey)
        }
        if let continuation = entry.continuation {
            pending = nil
            continuation.resume(returning: outcome)
        } else {
            entry.decided = outcome
            pending = entry
        }
    }

    /// Window-epoch invalidation shared by `windowOpened`/`windowClosed`: unconditionally clears
    /// `pending` and resolves its continuation false if one was parked (nothing to leak if not —
    /// no continuation was ever created for it yet). Deliberately unconditional even when a
    /// decision was already recorded (`entry.decided != nil` — e.g. an `approve()` that raced
    /// ahead of the caller's `awaitDecision` ever parking): a window-epoch change invalidates the
    /// pending request in every state, not just the ones still awaiting resolution. Fail-safe
    /// direction only — a pre-park `true` never survives a window boundary (spec must-fix 5:
    /// "deny/timeout/close invalidates it").
    private func invalidatePending(blockSource: Bool) {
        guard let entry = pending else { return }
        pending = nil
        if blockSource {
            blockedSources.insert(entry.request.source)
            // Finding H: block the key alongside the source (see `resolve`).
            blockedKeys.insert(entry.request.publicKey)
        }
        entry.continuation?.resume(returning: false)
    }
}

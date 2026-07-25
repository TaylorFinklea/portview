// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Per-session act-permission flag: gates whether a session may still perform effects, at the
/// single point where those effects actually happen (`perform`). One instance per session (unlike
/// `InputInjector.paused`, which is process-wide) — invalidating one session's capability must
/// never affect another's.
///
/// Withdrawal is TWO operations over TWO locks (Sol review C1, design §4/§10 R8):
///
/// - `markInvalid()` — **non-blocking**. Takes only `flagLock`, so it can never wait on an effect.
///   The instant it returns, no NEW effect can start on this capability.
/// - `drainInFlightEffect()` — **blocking**. Takes `effectLock`, so it returns only once an
///   already-in-flight effect has finished. It is the "wait out the residual" half.
/// - `invalidate()` — mark **then** drain, for the single-session terminal paths (the serve defer,
///   the admission-teardown guards) where the caller owns the one capability and wants both.
///
/// A batch teardown (`HostControl.beginRevoke`/`disconnectAll`/`evictLegacyAdmitted`) MUST mark
/// **every** snapshotted capability before draining any of them. With one combined lock, the
/// teardown blocked on the first session whose effect was in flight (e.g. a stalled
/// `FileHandle.write`) while every later session under the same key stayed valid — a revoked device
/// kept full control through its second session for the whole stall.
///
/// Lock ordering is one-directional and deadlock-free: `perform` takes `effectLock` then briefly
/// `flagLock`; `markInvalid`/`isValid` take only `flagLock`; `drainInFlightEffect` takes only
/// `effectLock`. Nothing ever holds `flagLock` while acquiring `effectLock`.
///
/// Mutual exclusion between `perform` and the drain is unchanged: while an effect runs, the drain
/// cannot return. The re-check of the flag *under* `effectLock` is what bounds the residual to **at
/// most one** effect per capability: a second `perform` that passed the fast-path check before the
/// mark serializes behind the in-flight effect and then observes the flag already false.
///
/// `perform`'s `effect` closure MUST be a strictly-synchronous, irreducible action at ONE effect
/// boundary — it must never `await`, never call back into this capability (a re-entrant
/// `perform`/`drainInFlightEffect` would deadlock on `effectLock`), and never wrap a compound
/// multi-step effect. (The one deliberate pair is `FileReceiver.dropTransfer`'s close+unlink of the
/// SAME file, which must not be split: see that method.)
final class SessionCapability: @unchecked Sendable {
    /// Guards `valid` only. Never held across an effect, so `markInvalid()` cannot wait on one.
    private let flagLock = NSLock()
    private var valid = true
    /// Held for the DURATION of an effect, so `drainInFlightEffect()` waits out one in-flight
    /// effect and two effects never overlap.
    private let effectLock = NSLock()

    init() {}

    var isValid: Bool {
        flagLock.lock()
        defer { flagLock.unlock() }
        return valid
    }

    /// Non-blocking withdrawal: after this returns, no NEW effect can start. An effect already
    /// in flight is NOT waited for — that is the accepted ≤ one-irreducible-effect residual, and
    /// `drainInFlightEffect()` is how a caller waits it out.
    func markInvalid() {
        flagLock.lock()
        valid = false
        flagLock.unlock()
    }

    /// Blocking half: returns once no effect is in flight. Meaningful only AFTER `markInvalid()`
    /// (on its own it guarantees nothing about what starts next).
    func drainInFlightEffect() {
        effectLock.lock()
        effectLock.unlock()
    }

    /// Mark then drain — the single-session terminal paths. Batch teardowns must NOT use this per
    /// session: it would drain session A before session B is even marked (the C1 defect).
    func invalidate() {
        markInvalid()
        drainInFlightEffect()
    }

    @discardableResult
    func perform(_ effect: () -> Void) -> Bool {
        // Fast, non-blocking reject: an already-withdrawn capability never queues behind an
        // in-flight effect just to be told no.
        guard isValid else { return false }
        effectLock.lock()
        defer { effectLock.unlock() }
        // Authoritative re-check UNDER the effect lock — this is what bounds the post-mark residual
        // to one effect: anything that queued behind the in-flight effect sees the mark here.
        guard isValid else { return false }
        effect()
        return true
    }
}

/// A lock-guarded slot that lets a serve task's OUTER cancellation handler reach the capability
/// created INSIDE `serveSession` (Sol review I3). Host shutdown (Stop Hosting / listener cancel)
/// cancels the serve task, and that handler used to `connection.close()` while the capability was
/// still valid — it was invalidated only later, in `serveSession`'s defer — so an already-dequeued
/// `.typeText` could keep posting its remaining CGEvents past the shutdown boundary (the
/// synchronous injection loop never observes task cancellation). Design §7 invariant 1 requires
/// Invalidate-First on EVERY terminal path, shutdown included.
///
/// Cancellation can also land BEFORE the capability exists (during the auth gate or the enrollment
/// ceremony), so the box REMEMBERS the withdrawal and applies it to whatever is published
/// afterwards: a session must never come up live on an already-cancelled serve task.
///
/// Only ever MARKS, never drains — a cancellation handler runs synchronously on the cancelling
/// thread and must not be wedged by a stalled in-flight effect. The full mark+drain `invalidate()`
/// still runs in `serveSession`'s defer as the loop unwinds.
final class SessionCapabilityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var capability: SessionCapability?
    private var withdrawn = false

    init() {}

    /// Publish this session's capability. If the serve task was already cancelled, the capability
    /// is marked invalid immediately.
    func publish(_ capability: SessionCapability) {
        lock.lock()
        self.capability = capability
        let alreadyWithdrawn = withdrawn
        lock.unlock()
        if alreadyWithdrawn { capability.markInvalid() }
    }

    /// Non-blocking withdrawal of whatever capability this session has published — or will.
    func markInvalid() {
        lock.lock()
        withdrawn = true
        let published = capability
        lock.unlock()
        published?.markInvalid()
    }
}

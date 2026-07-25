// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Per-session act-permission flag: gates whether a session may still perform effects, at the
/// single point where those effects actually happen (`perform`). One instance per session (unlike
/// `InputInjector.paused`, which is process-wide) — invalidating one session's capability must
/// never affect another's.
///
/// `perform` and `invalidate` share ONE lock (mirrors `InputInjector`'s authority-flag lock,
/// `InputInjector.swift:16-29`, but per-instance) so the two are mutually exclusive: a concurrent
/// `invalidate()` can never interleave with an in-flight `perform()` — either the effect runs to
/// completion under the lock and THEN invalidate flips the flag, or invalidate wins the lock first
/// and `perform` returns false without running the effect at all. There is no window where the
/// flag flips mid-effect.
///
/// `perform`'s `effect` closure MUST be a single, strictly-synchronous, irreducible action — it
/// must never `await`, never call back into this capability (re-entrant `perform`/`invalidate`
/// would deadlock on this lock), and never wrap a compound multi-step effect.
final class SessionCapability: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    init() {}

    var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return valid
    }

    func invalidate() {
        lock.lock()
        valid = false
        lock.unlock()
    }

    @discardableResult
    func perform(_ effect: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard valid else { return false }
        effect()
        return true
    }
}

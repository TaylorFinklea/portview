// SPDX-License-Identifier: Apache-2.0
import Foundation
import IOKit.pwr_mgt

/// Backend that actually talks to the system power manager. Injectable so `KeepAwake`'s transition
/// logic can be unit-tested without holding real assertions.
protocol KeepAwakeBackend: AnyObject, Sendable {
    /// Begin preventing idle DISPLAY sleep (keeps the screen lit so the remote viewer keeps seeing
    /// content; the system stays awake as a side effect). Idempotent at the backend level.
    func beginPreventingSleep()
    /// Release the sleep assertion(s). Idempotent.
    func endPreventingSleep()
    /// Declare local user activity — resets the idle timer so the screensaver (and thus the idle
    /// password lock) doesn't engage while a client is connected. Called once on acquire and then
    /// periodically. The DISPLAY-sleep assertion alone does NOT stop the screensaver/auto-lock.
    func declareUserActivity()
}

/// Schedules the periodic user-activity re-arm. Injectable so the re-arm can be driven deterministically
/// in tests instead of waiting on a wall-clock timer.
protocol KeepAwakeTicker: AnyObject, Sendable {
    func start(interval: TimeInterval, onFire: @escaping @Sendable () -> Void)
    func stop()
}

/// Holds a system keep-awake assertion for EXACTLY the span when >=1 streaming session is active.
/// Keyed by session id (a `Set<String>`), NOT a bare counter, so it's robust against `disconnectAll`
/// clearing sessions out from under the per-connection teardown (a late `sessionEnded` for an
/// already-removed id is a no-op, never a double-release). Lock-guarded; safe to call from any thread.
///
/// Caveat (by macOS design): preventing idle display sleep does not prevent a MANUAL lock or a
/// "require password immediately" policy lock — only the idle path. The periodic user-activity
/// declaration covers the idle screensaver-lock; everything else is surfaced via the lock-status
/// signal, not prevented.
final class KeepAwake: @unchecked Sendable {
    private let lock = NSLock()
    private let backend: KeepAwakeBackend
    private let ticker: KeepAwakeTicker
    private let activityInterval: TimeInterval
    private var active: Set<String> = []

    init(backend: KeepAwakeBackend,
         ticker: KeepAwakeTicker = DispatchKeepAwakeTicker(),
         activityInterval: TimeInterval = 30) {
        self.backend = backend
        self.ticker = ticker
        self.activityInterval = activityInterval
    }

    /// A streaming session became active. Acquires the assertion on the empty→non-empty transition.
    func sessionBegan(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        let wasEmpty = active.isEmpty
        active.insert(id)
        if wasEmpty && !active.isEmpty { startLocked() }
    }

    /// A streaming session ended. Releases the assertion on the non-empty→empty transition. A no-op
    /// if `id` wasn't active (e.g. already cleared by `endAll`), so it never double-releases.
    func sessionEnded(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        let removed = active.remove(id) != nil
        if removed && active.isEmpty { stopLocked() }
    }

    /// Every session ended at once (host "Disconnect all"). Releases the assertion if held.
    func endAll() {
        lock.lock(); defer { lock.unlock() }
        let had = !active.isEmpty
        active.removeAll()
        if had { stopLocked() }
    }

    private func startLocked() {
        backend.beginPreventingSleep()
        backend.declareUserActivity()
        ticker.start(interval: activityInterval) { [weak self] in self?.tick() }
    }

    private func stopLocked() {
        ticker.stop()
        backend.endPreventingSleep()
    }

    private func tick() {
        lock.lock(); defer { lock.unlock() }
        guard !active.isEmpty else { return }
        backend.declareUserActivity()
    }
}

/// Real ticker: a `DispatchSourceTimer`. Uses `.default` QoS (not `.utility`) because the re-arm is
/// deadline-sensitive — it must fire well under the ~60s screensaver threshold to keep suppressing the
/// idle lock, and a low-QoS timer can be coalesced/deferred too aggressively. Leeway scales (~10%).
final class DispatchKeepAwakeTicker: KeepAwakeTicker, @unchecked Sendable {
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    func start(interval: TimeInterval, onFire: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .default))
        t.schedule(deadline: .now() + interval, repeating: interval,
                   leeway: .milliseconds(max(5, Int(interval * 100))))
        t.setEventHandler(handler: onFire)
        timer = t
        t.resume()
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        timer?.cancel()
        timer = nil
    }
}

/// Real backend: an IOKit display-sleep power assertion + periodic user-activity declaration. Only
/// ever touched while `KeepAwake` holds its lock, so it needs no internal synchronization.
final class IOKitKeepAwakeBackend: KeepAwakeBackend, @unchecked Sendable {
    private var sleepAssertion: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
    private var activityAssertion: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
    private let reason = "Portview client connected" as CFString

    func beginPreventingSleep() {
        guard sleepAssertion == IOPMAssertionID(kIOPMNullAssertionID) else { return }
        var id = IOPMAssertionID(kIOPMNullAssertionID)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id)
        if result == kIOReturnSuccess { sleepAssertion = id }
    }

    func endPreventingSleep() {
        if sleepAssertion != IOPMAssertionID(kIOPMNullAssertionID) {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = IOPMAssertionID(kIOPMNullAssertionID)
        }
        if activityAssertion != IOPMAssertionID(kIOPMNullAssertionID) {
            IOPMAssertionRelease(activityAssertion)
            activityAssertion = IOPMAssertionID(kIOPMNullAssertionID)
        }
    }

    func declareUserActivity() {
        // Pass the existing id back in so repeated calls EXTEND one assertion rather than piling up.
        IOPMAssertionDeclareUserActivity(reason, kIOPMUserActiveLocal, &activityAssertion)
    }
}

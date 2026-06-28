import Testing
import Foundation
@testable import PortviewHostCore

/// `KeepAwake` holds a system power assertion for EXACTLY the span when >=1 streaming session is
/// active, keyed by session id (so it's robust against `disconnectAll` clearing sessions out from
/// under the per-session teardown). The backend is injectable so the transition logic is testable
/// without touching IOKit.
@Suite struct KeepAwakeTests {
    private final class SpyBackend: KeepAwakeBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var _begins = 0, _ends = 0, _activities = 0
        var begins: Int { lock.lock(); defer { lock.unlock() }; return _begins }
        var ends: Int { lock.lock(); defer { lock.unlock() }; return _ends }
        var activities: Int { lock.lock(); defer { lock.unlock() }; return _activities }
        func beginPreventingSleep() { lock.lock(); _begins += 1; lock.unlock() }
        func endPreventingSleep() { lock.lock(); _ends += 1; lock.unlock() }
        func declareUserActivity() { lock.lock(); _activities += 1; lock.unlock() }
    }

    /// A ticker the test fires by hand, so the periodic re-arm is verified deterministically (no
    /// wall-clock timer → no flakiness under parallel-suite load).
    private final class ManualTicker: KeepAwakeTicker, @unchecked Sendable {
        private let lock = NSLock()
        private var fire: (@Sendable () -> Void)?
        private var _started = 0, _stopped = 0
        var started: Int { lock.lock(); defer { lock.unlock() }; return _started }
        var stopped: Int { lock.lock(); defer { lock.unlock() }; return _stopped }
        func start(interval: TimeInterval, onFire: @escaping @Sendable () -> Void) {
            lock.lock(); fire = onFire; _started += 1; lock.unlock()
        }
        func stop() { lock.lock(); fire = nil; _stopped += 1; lock.unlock() }
        func fireOnce() { lock.lock(); let f = fire; lock.unlock(); f?() }
    }

    private func make() -> (KeepAwake, SpyBackend) {
        let spy = SpyBackend()
        return (KeepAwake(backend: spy, ticker: ManualTicker()), spy)
    }

    @Test func firstSessionBeginsKeepAwake() {
        let (k, spy) = make()
        k.sessionBegan("a")
        #expect(spy.begins == 1)
        #expect(spy.ends == 0)
        #expect(spy.activities >= 1) // an immediate user-activity kick on acquire
    }

    @Test func secondSessionDoesNotRebegin() {
        let (k, spy) = make()
        k.sessionBegan("a"); k.sessionBegan("b")
        #expect(spy.begins == 1)
    }

    @Test func duplicateBeginSameIdIsNoop() {
        let (k, spy) = make()
        k.sessionBegan("a"); k.sessionBegan("a")
        k.sessionEnded("a")
        #expect(spy.begins == 1)
        #expect(spy.ends == 1)
    }

    @Test func endingOneOfTwoKeepsAwake() {
        let (k, spy) = make()
        k.sessionBegan("a"); k.sessionBegan("b")
        k.sessionEnded("a")
        #expect(spy.ends == 0)
    }

    @Test func endingLastReleases() {
        let (k, spy) = make()
        k.sessionBegan("a"); k.sessionBegan("b")
        k.sessionEnded("a"); k.sessionEnded("b")
        #expect(spy.ends == 1)
    }

    @Test func endingUnknownIdIsNoop() {
        let (k, spy) = make()
        k.sessionBegan("a")
        k.sessionEnded("zzz")
        #expect(spy.ends == 0)
        #expect(spy.begins == 1)
    }

    @Test func endAllReleasesOnce() {
        let (k, spy) = make()
        k.sessionBegan("a"); k.sessionBegan("b")
        k.endAll()
        #expect(spy.ends == 1)
    }

    /// The disconnectAll desync guard: endAll clears the set, and a late per-session teardown for an
    /// already-removed id must NOT double-release.
    @Test func lateEndAfterEndAllDoesNotDoubleRelease() {
        let (k, spy) = make()
        k.sessionBegan("a")
        k.endAll()
        k.sessionEnded("a")
        #expect(spy.ends == 1)
    }

    @Test func reacquireAfterFullRelease() {
        let (k, spy) = make()
        k.sessionBegan("a"); k.sessionEnded("a")
        k.sessionBegan("b")
        #expect(spy.begins == 2)
    }

    /// The periodic user-activity re-arm is what actually suppresses the idle screensaver-lock (the
    /// display-sleep assertion alone doesn't). It must start on acquire, fire on every tick while
    /// active, and stop (no further fires) after release.
    @Test func periodicUserActivityReArmsWhileActive() {
        let spy = SpyBackend()
        let ticker = ManualTicker()
        let k = KeepAwake(backend: spy, ticker: ticker)
        k.sessionBegan("a")
        #expect(ticker.started == 1)
        #expect(spy.activities == 1) // immediate kick on acquire
        ticker.fireOnce(); ticker.fireOnce()
        #expect(spy.activities == 3) // + two re-arm ticks
        k.sessionEnded("a")
        #expect(ticker.stopped == 1)
        ticker.fireOnce() // ticker cleared its handler on stop → no further re-arm
        #expect(spy.activities == 3)
    }
}

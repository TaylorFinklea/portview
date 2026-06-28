import Testing
import Foundation
@testable import PortviewHostCore

/// `LockMonitor` detects host screen lock/unlock. `screenLocked(from:)` is the pure parse of the
/// CoreGraphics session dictionary (the authoritative seed); `emit` dedups so only true state
/// CHANGES are forwarded (the distributed lock/unlock notifications can repeat).
@Suite struct LockMonitorTests {
    @Test func parseAbsentKeyIsUnlocked() {
        #expect(LockMonitor.screenLocked(from: [:]) == false)
        #expect(LockMonitor.screenLocked(from: nil) == false)
        #expect(LockMonitor.screenLocked(from: ["CGSSessionOnConsole": 1]) == false)
    }

    @Test func parsePresentLockedKeyVariants() {
        #expect(LockMonitor.screenLocked(from: ["CGSSessionScreenIsLocked": 1]) == true)
        #expect(LockMonitor.screenLocked(from: ["CGSSessionScreenIsLocked": true]) == true)
        #expect(LockMonitor.screenLocked(from: ["CGSSessionScreenIsLocked": NSNumber(value: 1)]) == true)
    }

    @Test func emitForwardsOnlyTransitions() {
        let box = Recorder()
        let monitor = LockMonitor { locked in box.record(locked) }
        monitor.emit(true)   // change nil -> true
        monitor.emit(true)   // no change
        monitor.emit(false)  // change -> false
        monitor.emit(false)  // no change
        monitor.emit(true)   // change -> true
        #expect(box.values == [true, false, true])
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [Bool] = []
        var values: [Bool] { lock.lock(); defer { lock.unlock() }; return _values }
        func record(_ v: Bool) { lock.lock(); _values.append(v); lock.unlock() }
    }
}

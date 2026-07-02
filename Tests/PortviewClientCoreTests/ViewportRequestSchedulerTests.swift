import CoreGraphics
import XCTest

import PortviewClientCore

/// The viewport throttle (leading + trailing): the first request after a quiet period fires
/// immediately so host re-cropping tracks the cursor during a pan; a burst is rate-limited and the
/// latest resting position is delivered by the trailing fire; near-duplicates aren't re-sent.
@MainActor
final class ViewportRequestSchedulerTests: XCTestCase {
    func testLeadingEdgeFiresImmediately() {
        var sent: [CGRect] = []
        let scheduler = ViewportRequestScheduler(interval: .milliseconds(20)) { sent.append($0) }

        let crop = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        scheduler.request(crop)

        XCTAssertEqual(sent, [crop])  // synchronous leading edge, not after an idle delay
    }

    func testBurstDeliversLeadingThenLatestTrailing() async throws {
        let a = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        let b = CGRect(x: 0.15, y: 0.15, width: 0.7, height: 0.7)
        let latest = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        var sent: [CGRect] = []
        let scheduler = ViewportRequestScheduler(interval: .milliseconds(20)) { sent.append($0) }

        scheduler.request(a)        // leading → sent now
        scheduler.request(b)        // throttled (coalesced into pending)
        scheduler.request(latest)   // overwrites pending
        // Poll instead of a fixed sleep: under parallel-suite load the trailing MainActor task
        // can lag well past the nominal 20ms interval (this flaked at a fixed 60ms).
        let deadline = ContinuousClock.now + .seconds(5)
        while sent.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(sent, [a, latest])  // leading a, trailing latest; b coalesced away
    }

    func testResetCancelsTrailingFire() async throws {
        let a = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        let b = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        var sent: [CGRect] = []
        let scheduler = ViewportRequestScheduler(interval: .milliseconds(20)) { sent.append($0) }

        scheduler.request(a)   // leading → sent
        scheduler.request(b)   // schedules trailing
        scheduler.reset()      // cancels the trailing fire
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(sent, [a])
    }

    func testMicroJitterDoesNotDelayNextRealMove() async throws {
        // A near-duplicate (sub-epsilon jitter) must NOT reset the rate window, or the next real
        // move would be deferred a full interval (the latency bug). After the window has elapsed, a
        // jitter request followed by a real change must fire that change immediately (leading edge).
        let a = CGRect(x: 0.10, y: 0.10, width: 0.50, height: 0.50)
        let b = CGRect(x: 0.30, y: 0.30, width: 0.50, height: 0.50)
        var sent: [CGRect] = []
        let scheduler = ViewportRequestScheduler(interval: .milliseconds(20)) { sent.append($0) }

        scheduler.request(a)                                              // leading → sends a
        try await Task.sleep(for: .milliseconds(40))                      // window elapses
        scheduler.request(CGRect(x: 0.1003, y: 0.1003, width: 0.50, height: 0.50))  // jitter ~ a (no send)
        scheduler.request(b)                                              // real move

        XCTAssertEqual(sent, [a, b])  // b fired immediately, not deferred to a trailing tick
    }

    func testDoesNotResendNearDuplicate() async throws {
        let crop = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        var sent: [CGRect] = []
        let scheduler = ViewportRequestScheduler(interval: .milliseconds(20)) { sent.append($0) }

        scheduler.request(crop)
        try await Task.sleep(for: .milliseconds(40))
        scheduler.request(CGRect(x: 0.2005, y: 0.2005, width: 0.6005, height: 0.6005))
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(sent, [crop])  // near-duplicate suppressed
    }
}

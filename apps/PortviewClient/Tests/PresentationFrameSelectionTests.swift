import PortviewClientCore
import XCTest

/// The renderer's PTS frame-selection: frames submitted with a host-timeline PTS stage by their
/// `PresentationClock` target present time, and each display-link tick pops the frame due at the
/// current clock time — the NEWEST due one — discarding frames already passed. A frame more than
/// ~2 frame intervals late is dropped, not shown. Pure logic (`PresentationFrameQueue` +
/// `PresentationClock`, exactly what `MetalVideoRenderer.submit`/`tick` compose); the Metal draw
/// itself needs a device and is exercised on-device.
final class PresentationFrameSelectionTests: XCTestCase {
    /// Audio anchored at host pts 1_000_000 ↔ local 0 → offset 1_000_000, with 50ms jitter headroom.
    private let clock = PresentationClock(hostClockOffsetMicros: 1_000_000, presentationDelayMicros: 50_000)

    private func submit(_ label: String, ptsMicros: UInt64, into queue: inout PresentationFrameQueue<String>) {
        queue.enqueue(label, targetMicros: clock.targetPresentTimeMicros(forPTSMicros: ptsMicros))
    }

    func testTickSelectsDueFrameAndDiscardsPassedOnes() {
        var queue = PresentationFrameQueue<String>(capacity: 4)
        // 30 fps PTS spacing on the host timeline → local targets 50_000 / 83_333 / 116_666.
        submit("v1", ptsMicros: 1_000_000, into: &queue)
        submit("v2", ptsMicros: 1_033_333, into: &queue)
        submit("v3", ptsMicros: 1_066_666, into: &queue)

        XCTAssertNil(queue.popDue(now: 40_000))          // nothing due yet — everything stays staged
        XCTAssertEqual(queue.count, 3)
        XCTAssertEqual(queue.popDue(now: 90_000), "v2")  // the frame due at the clock time…
        XCTAssertEqual(queue.count, 1)                   // …discarding v1 (already passed); v3 waits
        XCTAssertNil(queue.popDue(now: 90_000))          // no re-emission on the next tick
        XCTAssertEqual(queue.popDue(now: 116_666), "v3")
        XCTAssertTrue(queue.isEmpty)
    }

    func testFrameMoreThanTwoIntervalsLateIsDroppedNotShown() {
        var queue = PresentationFrameQueue<String>(capacity: 4)
        submit("a", ptsMicros: 1_000_000, into: &queue)  // target 50_000
        submit("b", ptsMicros: 1_033_333, into: &queue)  // target 83_333; measured interval 33_333
        // At 83_333 + 2×33_333 = 149_999 the due frame b is exactly at the late budget — shown.
        XCTAssertEqual(queue.popDue(now: 149_999), "b")
        submit("c", ptsMicros: 1_066_666, into: &queue)  // target 116_666
        // One micro past the budget: dropped, not shown — and removed, not retried.
        XCTAssertNil(queue.popDue(now: 116_666 + 2 * 33_333 + 1))
        XCTAssertTrue(queue.isEmpty)
    }

    /// A wedged clock (targets never coming due) must not accumulate decoded frames: the queue is
    /// small and fixed, evicting oldest-first.
    func testCapacityDropsOldestSoAWedgedClockCannotAccumulate() {
        var queue = PresentationFrameQueue<String>(capacity: 4)
        for i in 0..<20 {
            submit("v\(i)", ptsMicros: 2_000_000 + UInt64(i) * 33_333, into: &queue)
            XCTAssertLessThanOrEqual(queue.count, 4)
        }
        // Only the newest 4 remain; at v19's target the newest due frame wins.
        XCTAssertEqual(queue.popDue(now: clock.targetPresentTimeMicros(forPTSMicros: 2_000_000 + 19 * 33_333)), "v19")
        XCTAssertTrue(queue.isEmpty)
    }
}

// SPDX-License-Identifier: Apache-2.0
import PortviewClientCore
import XCTest

/// The renderer's PTS frame-selection: frames submitted with a host-timeline PTS stage by their
/// `PresentationClock` target present time, and each display-link tick pops the frame due at the
/// current clock time — the NEWEST due one — discarding frames already passed. A frame more than
/// ~2 frame intervals late is dropped only when a newer frame is staged to replace it; a lone late
/// frame is shown anyway (late beats wrong), and at capacity with nothing due the oldest staged
/// frame is shown (liveness valve). Pure logic (`PresentationFrameQueue` + `PresentationClock`,
/// exactly what `MetalVideoRenderer.submit`/`tick` compose); the Metal draw itself needs a device
/// and is exercised on-device.
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

    func testFrameMoreThanTwoIntervalsLateIsDroppedWhenANewerFrameIsStaged() {
        var queue = PresentationFrameQueue<String>(capacity: 4)
        submit("a", ptsMicros: 1_000_000, into: &queue)  // target 50_000
        submit("b", ptsMicros: 1_033_333, into: &queue)  // target 83_333; measured interval 33_333
        // At 83_333 + 2×33_333 = 149_999 the due frame b is exactly at the late budget — shown.
        XCTAssertEqual(queue.popDue(now: 149_999), "b")
        submit("c", ptsMicros: 1_066_666, into: &queue)  // target 116_666
        submit("d", ptsMicros: 3_066_666, into: &queue)  // target 2_116_666 (insane 2s spacing ignored)
        // One micro past c's budget with d staged behind it: c is obsoleted — dropped, not shown.
        XCTAssertNil(queue.popDue(now: 116_666 + 2 * 33_333 + 1))
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.popDue(now: 2_116_666), "d")
    }

    /// ScreenCaptureKit delivers frames on content change: a late content-change frame with NOTHING
    /// newer staged may have no successor for minutes — dropping it would pin the pre-change screen.
    /// Late beats wrong: a lone late frame is shown.
    func testLoneLateFrameIsShownNotDropped() {
        var queue = PresentationFrameQueue<String>(capacity: 4)
        submit("contentChange", ptsMicros: 1_000_000, into: &queue)  // target 50_000
        XCTAssertEqual(queue.popDue(now: 10_000_000), "contentChange")  // far past budget, still shown
        XCTAssertTrue(queue.isEmpty)
    }

    /// A skewed anchor (first audio frame delayed behind the session-start keyframe burst) or a
    /// wedged clock leaves every staged target far-future — nothing ever comes due while frames
    /// keep arriving. At capacity with nothing due the oldest frame is shown anyway, so video
    /// cannot freeze while audio plays.
    func testAtCapacityWithNothingDueShowsOldestFrame() {
        var queue = PresentationFrameQueue<String>(capacity: 4)
        for i in 0..<4 {
            submit("v\(i)", ptsMicros: 60_000_000 + UInt64(i) * 33_333, into: &queue)
        }
        XCTAssertEqual(queue.popDue(now: 0), "v0")  // full of never-due frames → oldest shown
        XCTAssertEqual(queue.count, 3)
        XCTAssertNil(queue.popDue(now: 0))          // below capacity: normal staging resumes
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

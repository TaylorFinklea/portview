import Testing
import PortviewClientCore

/// PresentationFrameQueue: bounded, target-time-ordered staging for decoded video frames. Unlike
/// PTSJitterBuffer (which drains EVERY due element — right for audio, where all buffers must play),
/// a display shows exactly ONE frame per tick: `popDue` returns the newest due frame and discards
/// the older due ones it obsoletes. A due frame more than the late budget (~2 frame intervals,
/// measured from enqueue spacing) past its target is dropped only when a newer frame is staged to
/// replace it — a lone late frame is shown anyway (late beats wrong). At capacity with nothing due
/// the oldest staged frame is yielded (liveness valve: a skewed/wedged clock can't freeze video).
@Suite struct PresentationFrameQueueTests {
    @Test func nothingDueKeepsFramesStaged() {
        var queue = PresentationFrameQueue<String>(capacity: 4)
        queue.enqueue("f100", targetMicros: 100_000)
        queue.enqueue("f133", targetMicros: 133_000)
        #expect(queue.popDue(now: 99_999) == nil)
        #expect(queue.count == 2)
    }

    @Test func selectsNewestDueFrameAndDiscardsPassedOnes() {
        var queue = PresentationFrameQueue<String>(capacity: 8)
        for (target, label) in [(Int64(10_000), "f1"), (20_000, "f2"), (30_000, "f3"), (40_000, "f4")] {
            queue.enqueue(label, targetMicros: target)
        }
        #expect(queue.popDue(now: 25_000) == "f2")  // newest due; f1 (already passed) is discarded
        #expect(queue.count == 2)                   // f3/f4 still awaiting their targets
        #expect(queue.popDue(now: 25_000) == nil)   // no double emission
        #expect(queue.popDue(now: 40_000) == "f4")  // f3 obsoleted by the also-due f4
        #expect(queue.isEmpty)
    }

    /// Boundary: exactly the late budget past the target is NOT "more than" — still shown; one
    /// microsecond further, with a newer frame staged behind it, is dropped AND removed (obsoleted
    /// — the successor will be shown instead, not the stale frame).
    @Test func dueFramePastLateBudgetIsDroppedWhenANewerFrameIsStaged() {
        var queue = PresentationFrameQueue<String>(capacity: 4)
        queue.enqueue("atBudget", targetMicros: 0)
        // Default interval 33_333 (30 fps) → budget 66_666.
        #expect(queue.lateBudgetMicros == 66_666)
        #expect(queue.popDue(now: 66_666) == "atBudget")
        queue.enqueue("tooLate", targetMicros: 0)
        queue.enqueue("successor", targetMicros: 2_000_000)  // insane 2s spacing — budget unchanged
        #expect(queue.lateBudgetMicros == 66_666)
        #expect(queue.popDue(now: 66_667) == nil)  // tooLate obsoleted by the staged successor
        #expect(queue.count == 1)                  // successor still awaiting its target
        #expect(queue.popDue(now: 2_000_000) == "successor")
        #expect(queue.isEmpty)
    }

    /// The source delivers frames on content change: a late content-change frame with NOTHING newer
    /// staged may have no successor for minutes — dropping it would pin the pre-change screen.
    /// Late beats wrong: a lone late frame is shown.
    @Test func loneLateFrameIsShownNotDropped() {
        var queue = PresentationFrameQueue<String>(capacity: 4)
        queue.enqueue("contentChange", targetMicros: 0)
        #expect(queue.popDue(now: 10_000_000) == "contentChange")  // far past budget, still shown
        #expect(queue.isEmpty)
    }

    @Test func measuredEnqueueSpacingDrivesLateBudget() {
        var queue = PresentationFrameQueue<String>(capacity: 8)
        queue.enqueue("a", targetMicros: 0)
        queue.enqueue("b", targetMicros: 10_000)   // 100 fps stream → interval 10_000, budget 20_000
        #expect(queue.lateBudgetMicros == 20_000)
        #expect(queue.popDue(now: 30_000) == "b")  // b is exactly 20_000 late — at budget, shown
        queue.enqueue("c", targetMicros: 20_000)
        queue.enqueue("d", targetMicros: 2_020_000)  // insane 2s spacing — budget stays 20_000
        #expect(queue.lateBudgetMicros == 20_000)
        #expect(queue.popDue(now: 40_001) == nil)  // c is 20_001 late — past budget, obsoleted by d
        #expect(queue.count == 1)
    }

    /// A wedged clock (targets never coming due) must not accumulate frames: over capacity the
    /// oldest is evicted, so the queue holds a small fixed number of pixel-buffer-sized elements.
    @Test func capacityEvictsOldestFirst() {
        var queue = PresentationFrameQueue<String>(capacity: 3)
        for i in 1...10 {
            queue.enqueue("f\(i)", targetMicros: Int64(i) * 33_333)
            #expect(queue.count <= 3)
        }
        // Only f8/f9/f10 remain; at f10's target the newest due wins and the rest are discarded.
        #expect(queue.popDue(now: 10 * 33_333) == "f10")
        #expect(queue.isEmpty)
    }

    /// Liveness valve: a skewed anchor (first audio frame delayed behind the session-start keyframe
    /// burst) or a wedged clock leaves every staged target far-future — nothing ever comes due while
    /// frames keep arriving. At capacity with nothing due, the oldest staged frame is yielded anyway,
    /// bounding the freeze by construction; below capacity normal PTS staging is untouched
    /// (`nothingDueKeepsFramesStaged` above).
    @Test func atCapacityWithNothingDueYieldsOldestFrame() {
        var queue = PresentationFrameQueue<String>(capacity: 3)
        for (target, label) in [(Int64(10_000_000), "f1"), (10_033_333, "f2"), (10_066_666, "f3")] {
            queue.enqueue(label, targetMicros: target)
        }
        #expect(queue.popDue(now: 0) == "f1")  // full of never-due frames → oldest is shown
        #expect(queue.count == 2)
        #expect(queue.popDue(now: 0) == nil)   // below capacity again → normal staging resumes
        #expect(queue.count == 2)
    }

    /// A late-arriving lower-PTS frame never displaces a newer one: selection is by target order,
    /// not arrival order.
    @Test func outOfOrderEnqueueStillSelectsByTarget() {
        var queue = PresentationFrameQueue<String>(capacity: 4)
        queue.enqueue("newer", targetMicros: 30_000)
        queue.enqueue("older", targetMicros: 10_000)
        #expect(queue.popDue(now: 30_000) == "newer")
        #expect(queue.isEmpty)  // "older" was already passed → discarded
    }

    @Test func removeAllClearsStagedFrames() {
        var queue = PresentationFrameQueue<String>(capacity: 4)
        queue.enqueue("a", targetMicros: 0)
        queue.enqueue("b", targetMicros: 10_000)  // narrows the measured interval…
        queue.removeAll()
        #expect(queue.isEmpty)
        #expect(queue.popDue(now: 10_000) == nil)
        // …and removeAll resets it: a fresh session re-measures from its own spacing.
        #expect(queue.lateBudgetMicros == 2 * PresentationFrameQueue<String>.defaultFrameIntervalMicros)
    }
}

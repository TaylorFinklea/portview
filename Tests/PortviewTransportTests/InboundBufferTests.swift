// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import PortviewProtocol
@testable import PortviewTransport

@Suite struct InboundBufferTests {
    private func chunk(id: UInt32 = 1, bytes: Int, isLast: Bool = false) -> AnyMessage {
        .fileChunk(FileChunk(transferID: id, isLast: isLast, data: [UInt8](repeating: 0, count: bytes)))
    }

    private func video(_ sequence: UInt64, isKeyframe: Bool = false) -> AnyMessage {
        .videoFrame(VideoFrame(sequence: sequence, ptsMicros: sequence, isKeyframe: isKeyframe,
                               displayID: 0, width: 1, height: 1, data: [0]))
    }

    private func audio(_ sequence: UInt64) -> AnyMessage {
        .audioFrame(AudioFrame(sampleRate: 48_000, channels: 2, ptsMicros: sequence,
                               data: [0, 0, 0, 0]))
    }

    @Test func controlPreservesFIFOOrder() async {
        let buffer = InboundBuffer()
        buffer.enqueue([.bye(Bye(reason: "a")), .clipboardUpdate(ClipboardUpdate(text: "x")), .bye(Bye(reason: "b"))])
        #expect(await buffer.next() == .bye(Bye(reason: "a")))
        #expect(await buffer.next() == .clipboardUpdate(ClipboardUpdate(text: "x")))
        #expect(await buffer.next() == .bye(Bye(reason: "b")))
    }

    @Test func videoCoalescesToNewestTwo() async {
        let buffer = InboundBuffer()
        buffer.enqueue([video(1), video(2), video(3), video(4), video(5)])
        #expect(buffer.videoFramesBuffered == 2)
        #expect(buffer.droppedVideoFrames == 3)
        #expect(await buffer.next() == video(4))
        #expect(await buffer.next() == video(5))
    }

    @Test func overflowCannotEvictTheNewestKeyframe() async {
        // A keyframe is the decoder's only resync point (2026-07-16 freeze): the recovery IDR the
        // client just requested must not be coalesced away by the very burst it recovers from.
        // Deltas around it are still newest-wins.
        let buffer = InboundBuffer()
        buffer.enqueue([video(10, isKeyframe: true), video(11), video(12), video(13), video(14)])
        #expect(buffer.videoFramesBuffered == 2)
        #expect(await buffer.next() == video(10, isKeyframe: true))
        #expect(await buffer.next() == video(14))
    }

    @Test func aNewerKeyframeSupersedesTheOldPin() async {
        let buffer = InboundBuffer()
        buffer.enqueue([video(1, isKeyframe: true), video(2), video(3, isKeyframe: true), video(4), video(5)])
        #expect(await buffer.next() == video(3, isKeyframe: true))
        #expect(await buffer.next() == video(5))
    }

    @Test func keyframeArrivingAfterDeltaOverflowIsRetained() async {
        // The recovery scenario end-to-end: deltas overflowed (consumer stalled), then the host's
        // requested IDR lands mid-burst — it must still reach the consumer.
        let buffer = InboundBuffer()
        buffer.enqueue([video(1), video(2), video(3)])
        buffer.enqueue([video(4, isKeyframe: true), video(5), video(6), video(7)])
        #expect(await buffer.next() == video(4, isKeyframe: true))
        #expect(await buffer.next() == video(7))
    }

    @Test func allKeyframeLaneStillBoundedAndNewestWins() async {
        let buffer = InboundBuffer()
        buffer.enqueue([video(1, isKeyframe: true), video(2, isKeyframe: true), video(3, isKeyframe: true)])
        #expect(buffer.videoFramesBuffered == 2)
        #expect(await buffer.next() == video(2, isKeyframe: true))
        #expect(await buffer.next() == video(3, isKeyframe: true))
    }

    @Test func controlDrainsBeforeBufferedVideo() async {
        let buffer = InboundBuffer()
        buffer.enqueue([video(1), .bye(Bye(reason: "ctl")), video(2)])
        #expect(await buffer.next() == .bye(Bye(reason: "ctl")))
        #expect(await buffer.next() == video(1))
        #expect(await buffer.next() == video(2))
    }

    @Test func audioBurstCannotStarveVideo() async {
        let buffer = InboundBuffer()
        buffer.enqueue([video(1)])
        buffer.enqueue((1...20).map { audio(UInt64($0)) })

        // Audio is realtime media, not control. The bounded audio lane retains the newest eight
        // packets, then alternates with video instead of allowing an audio burst to hold the
        // picture on its initial frame indefinitely.
        #expect(await buffer.next() == audio(13))
        #expect(await buffer.next() == video(1))
    }

    @Test func suspendedNextWakesOnEnqueue() async {
        let buffer = InboundBuffer()
        let task = Task { await buffer.next() }
        try? await Task.sleep(for: .milliseconds(50)) // let next() park
        buffer.enqueue([.bye(Bye(reason: "wake"))])
        #expect(await task.value == .bye(Bye(reason: "wake")))
    }

    @Test func finishDrainsRemainingThenNil() async {
        let buffer = InboundBuffer()
        buffer.enqueue([.bye(Bye(reason: "last"))])
        buffer.finish()
        #expect(await buffer.next() == .bye(Bye(reason: "last")))
        #expect(await buffer.next() == nil)
        #expect(await buffer.next() == nil)
    }

    @Test func finishWakesASuspendedNextWithNil() async {
        let buffer = InboundBuffer()
        let task = Task { await buffer.next() }
        try? await Task.sleep(for: .milliseconds(50))
        buffer.finish()
        #expect(await task.value == nil)
    }

    @Test func cancelledNextResumesNil() async {
        let buffer = InboundBuffer()
        let task = Task { await buffer.next() }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        #expect(await task.value == nil)
    }

    @Test func enqueueSignalsPauseAtControlHighWater() {
        let buffer = InboundBuffer(controlHighWaterBytes: 300, controlLowWaterBytes: 100)
        #expect(buffer.enqueue([chunk(bytes: 100)]) == .accepted(pauseReceive: false))
        #expect(buffer.enqueue([chunk(bytes: 200)]) == .accepted(pauseReceive: true))
        #expect(buffer.isReceivePaused)
    }

    @Test func resumeFiresOnceBelowLowWater() async {
        let resumes = ResumeCounter()
        let buffer = InboundBuffer(controlHighWaterBytes: 250, controlLowWaterBytes: 100) {
            resumes.increment()
        }
        buffer.enqueue([chunk(bytes: 100), chunk(bytes: 100), chunk(bytes: 100)])
        #expect(buffer.isReceivePaused)
        _ = await buffer.next() // 200 buffered — still ≥ low water
        #expect(resumes.count == 0)
        _ = await buffer.next() // 100 buffered — still ≥ low water
        #expect(resumes.count == 0)
        _ = await buffer.next() // 0 buffered — below low water: resume exactly once
        #expect(resumes.count == 1)
        #expect(!buffer.isReceivePaused)
    }

    @Test func videoFramesDoNotCountTowardControlBytes() {
        let buffer = InboundBuffer(controlHighWaterBytes: 100, controlLowWaterBytes: 50)
        #expect(buffer.enqueue([video(1), video(2), video(3)]) == .accepted(pauseReceive: false))
        #expect(!buffer.isReceivePaused)
    }

    // MARK: - finishDiscardingBuffered (han.4 finding 7 — discard-not-drain)

    /// THE PRIMARY GUARANTEE (100%, no residual): a buffered BACKLOG — messages already decoded
    /// and appended, with NO consumer parked to race — is discarded in full. This is the case an
    /// actual revoke hits almost always (a consumer is rarely suspended in `next()` at the instant
    /// a `finishDiscardingBuffered()` lands); the bounded parked-waiter race below is the separate,
    /// accepted residual (R9) for the much rarer case where a consumer happens to be parked.
    @Test func finishDiscardingBufferedClearsAllThreeLanesSoNextReturnsNil() async {
        let buffer = InboundBuffer()
        buffer.enqueue([.bye(Bye(reason: "control-1")), .clipboardUpdate(ClipboardUpdate(text: "control-2")),
                        .bye(Bye(reason: "control-3"))])
        buffer.enqueue([video(1, isKeyframe: true), video(2)])
        buffer.enqueue([audio(1), audio(2)])
        buffer.finishDiscardingBuffered()
        #expect(await buffer.next() == nil)
        #expect(await buffer.next() == nil)
    }

    @Test func finishDiscardingBufferedWakesAParkedWaiterWithNil() async {
        let buffer = InboundBuffer()
        let task = Task { await buffer.next() }
        try? await Task.sleep(for: .milliseconds(50)) // let next() park
        buffer.finishDiscardingBuffered()
        #expect(await task.value == nil)
    }

    @Test func finishDiscardingBufferedContrastsWithFinishWhichDrains() async {
        // finish() DRAINS already-buffered messages (existing, intentional behavior);
        // finishDiscardingBuffered() DISCARDS them instead. Same buffered payload, opposite
        // outcome — the security-critical distinction (han.4 finding 7): a revoked peer's queued
        // input must never be delivered.
        let draining = InboundBuffer()
        draining.enqueue([.bye(Bye(reason: "drained"))])
        draining.finish()
        #expect(await draining.next() == .bye(Bye(reason: "drained")))
        #expect(await draining.next() == nil)

        let discarding = InboundBuffer()
        discarding.enqueue([.bye(Bye(reason: "discarded"))])
        discarding.finishDiscardingBuffered()
        #expect(await discarding.next() == nil)
    }

    /// TERMINAL: once `finishDiscardingBuffered()` has run, the buffer stays permanently closed —
    /// every subsequent `enqueue` is rejected (never appended), and a waiter that parks in `next()`
    /// AFTER the finish resolves nil immediately rather than ever suspending on new work.
    @Test func terminalAfterFinishDiscardingBufferedEveryEnqueueDropsAndALaterWaiterResolvesNil() async {
        let buffer = InboundBuffer()
        buffer.finishDiscardingBuffered()

        #expect(buffer.enqueue([.bye(Bye(reason: "post-discard-1"))]) == .droppedFinished)
        #expect(buffer.enqueue([.bye(Bye(reason: "post-discard-2"))]) == .droppedFinished)

        // A "waiter parked after finish" — next() called once the buffer is already terminal.
        #expect(await buffer.next() == nil)
        #expect(await buffer.next() == nil)
    }

    /// BARRIER: races a real concurrent `enqueue` against `finishDiscardingBuffered` from two
    /// threads with no artificial ordering, many trials. The shared lock must linearize the two
    /// operations — the enqueue either completes fully BEFORE the discard (and its message is
    /// cleared) or fully AFTER (and is rejected as `.droppedFinished`) — so the raced message can
    /// NEVER survive to a later `next()`, whichever thread the OS scheduler favors.
    @Test func concurrentEnqueueRacingDiscardNeverYieldsALaterMessage() async {
        for trial in 0..<50 {
            let buffer = InboundBuffer()
            let message = AnyMessage.bye(Bye(reason: "race-\(trial)"))
            let startGate = DispatchSemaphore(value: 0)
            let doneGroup = DispatchGroup()
            let outcomeBox = OutcomeBox()

            doneGroup.enter()
            DispatchQueue.global().async {
                startGate.wait()
                outcomeBox.set(buffer.enqueue([message]))
                doneGroup.leave()
            }
            doneGroup.enter()
            DispatchQueue.global().async {
                startGate.wait()
                buffer.finishDiscardingBuffered()
                doneGroup.leave()
            }
            startGate.signal()
            startGate.signal()
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                doneGroup.notify(queue: .global()) { cont.resume() }
            }

            // Whichever order won the lock, the buffer must end up fully empty: the enqueue's
            // message was either never appended (.droppedFinished) or appended-then-cleared.
            #expect(await buffer.next() == nil, "trial \(trial)")
            if outcomeBox.get() == .droppedFinished {
                #expect(buffer.controlBytesBuffered == 0, "trial \(trial)")
            }
        }
    }

    /// PARKED-WAITER residual — adjudicated han.4 design doc §4 as accepted residual **R9**
    /// (2026-07-25, Task-2 review adjudication): a consumer already suspended in `next()` (the
    /// buffer's normal resting state) racing a SINGLE `enqueue` against `finishDiscardingBuffered`
    /// may receive AT MOST that one message — no general synchronization primitive (raw lock, GCD
    /// serial queue) can make either side an unconditional winner of a truly simultaneous race (see
    /// `.superpowers/sdd/task-2-report.md` "Fix follow-up" for the empirical investigation: the
    /// reviewer's suggested queue-serialization mechanism was measured WORSE, ~46% delivered vs the
    /// direct call's ~1%, so the direct call — commit 9e00797, unchanged — stays). This residual is
    /// bounded (never a SECOND message) and backstopped by the capability effect-boundary guard
    /// (han.4 Task 5): a message that slips through here still can't perform its effect once
    /// `SessionCapability.invalidate()` — which always runs before this discard in the revoke
    /// ordering — has landed. Does NOT assert "never delivered" — that is not achievable for a
    /// single truly-simultaneous enqueue and asserting it would make this test permanently flaky.
    @Test func parkedWaiterConcurrentEnqueueIsBoundedToOneMessage() async {
        for trial in 0..<100 {
            let buffer = InboundBuffer()
            let message = AnyMessage.bye(Bye(reason: "race-\(trial)"))

            let waiterTask = Task { await buffer.next() }
            try? await Task.sleep(for: .milliseconds(50)) // let next() park

            let startGate = DispatchSemaphore(value: 0)
            let doneGroup = DispatchGroup()

            // Dedicated OS threads, not shared-pool GCD work items: `DispatchQueue.global()` was
            // empirically found (see task-2-report.md) to favor whichever racer's block was
            // SUBMITTED first in program order — an artifact of that pool's own scheduling, not a
            // property of the code under test.
            doneGroup.enter()
            Thread.detachNewThread {
                startGate.wait()
                _ = buffer.enqueue([message])
                doneGroup.leave()
            }
            doneGroup.enter()
            Thread.detachNewThread {
                startGate.wait()
                buffer.finishDiscardingBuffered()
                doneGroup.leave()
            }
            startGate.signal()
            startGate.signal()
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                doneGroup.notify(queue: .global()) { cont.resume() }
            }

            // Bounded to AT MOST one message: if the race delivered it, that message must be THIS
            // trial's own (never a stray from anywhere else) — the accepted R9 residual.
            let firstResult = await waiterTask.value
            if let firstResult {
                #expect(firstResult == message, "trial \(trial): a delivered message must be this race's own")
            }

            // TERMINAL from here regardless of the first race's outcome: never a second message.
            #expect(buffer.enqueue([.bye(Bye(reason: "second-\(trial)"))]) == .droppedFinished, "trial \(trial)")
            #expect(await buffer.next() == nil, "trial \(trial)")
        }
    }
}

/// Test helper: a lock-guarded box for reading a racing thread's `enqueue` verdict back on the
/// awaiting task.
private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: InboundBuffer.EnqueueOutcome?
    func set(_ outcome: InboundBuffer.EnqueueOutcome) { lock.lock(); value = outcome; lock.unlock() }
    func get() -> InboundBuffer.EnqueueOutcome? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Test helper: lock-free enough for the single-threaded assertions above.
private final class ResumeCounter: @unchecked Sendable {
    private(set) var count = 0
    func increment() { count += 1 }
}

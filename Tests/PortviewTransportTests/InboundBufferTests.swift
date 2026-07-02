import Testing
import PortviewProtocol
@testable import PortviewTransport

@Suite struct InboundBufferTests {
    private func chunk(id: UInt32 = 1, bytes: Int, isLast: Bool = false) -> AnyMessage {
        .fileChunk(FileChunk(transferID: id, isLast: isLast, data: [UInt8](repeating: 0, count: bytes)))
    }

    private func video(_ sequence: UInt64) -> AnyMessage {
        .videoFrame(VideoFrame(sequence: sequence, ptsMicros: sequence, isKeyframe: false,
                               displayID: 0, width: 1, height: 1, data: [0]))
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

    @Test func controlDrainsBeforeBufferedVideo() async {
        let buffer = InboundBuffer()
        buffer.enqueue([video(1), .bye(Bye(reason: "ctl")), video(2)])
        #expect(await buffer.next() == .bye(Bye(reason: "ctl")))
        #expect(await buffer.next() == video(1))
        #expect(await buffer.next() == video(2))
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
        #expect(buffer.enqueue([chunk(bytes: 100)]) == false)
        #expect(buffer.enqueue([chunk(bytes: 200)]) == true)
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
        #expect(buffer.enqueue([video(1), video(2), video(3)]) == false)
        #expect(!buffer.isReceivePaused)
    }
}

/// Test helper: lock-free enough for the single-threaded assertions above.
private final class ResumeCounter: @unchecked Sendable {
    private(set) var count = 0
    func increment() { count += 1 }
}

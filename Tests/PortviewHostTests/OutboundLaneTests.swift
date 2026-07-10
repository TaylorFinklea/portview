import Testing
import Foundation
import PortviewProtocol
@testable import PortviewHostCore

/// The session-owned ordered outbound lane: messages drain in enqueue order through a single
/// awaited sink, `finish()` stops all further delivery (teardown ownership — the reason the
/// fire-and-forget `Task { send }` pattern was replaced), and a coalescing key keeps only the
/// latest same-key payload.
@Suite struct OutboundLaneTests {
    private actor Recorder {
        private(set) var texts: [String] = []
        func append(_ t: String) { texts.append(t) }
        func snapshot() -> [String] { texts }
        func count() -> Int { texts.count }
    }

    private static func label(_ message: AnyMessage) -> String {
        switch message {
        case .clipboardUpdate(let u): u.text
        case .cursorPosition(let p): "cursor:\(p.nx)"  // raw UInt16 — normalizedX re-quantizes
        default: "other"
        }
    }

    @Test func messagesDrainInEnqueueOrder() async {
        let recorder = Recorder()
        let lane = OutboundLane<AnyMessage>(sink: { message in await recorder.append(Self.label(message)) })

        for i in 1...20 { lane.enqueue(.clipboardUpdate(ClipboardUpdate(text: "m\(i)"))) }

        for _ in 0..<500 {
            if await recorder.count() == 20 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await recorder.snapshot() == (1...20).map { "m\($0)" })
        lane.finish()
    }

    @Test func finishStopsDeliveryIncludingPendingAndLaterEnqueues() async {
        // Gate the sink on the FIRST message so the queue is guaranteed non-empty when finish()
        // runs — pinning that finish drops pending messages, not just future ones.
        let recorder = Recorder()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        let gate = OneShotGate()
        let lane = OutboundLane<AnyMessage>(sink: { message in
            await recorder.append(Self.label(message))
            if await gate.first() {
                var it = release.makeAsyncIterator()
                _ = await it.next()  // hold the drain until the test releases it
            }
        })

        lane.enqueue(.clipboardUpdate(ClipboardUpdate(text: "delivered")))
        // Wait until the drain is inside the held sink call.
        for _ in 0..<500 {
            if await recorder.count() == 1 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        lane.enqueue(.clipboardUpdate(ClipboardUpdate(text: "pending-at-finish")))
        lane.finish()
        lane.enqueue(.clipboardUpdate(ClipboardUpdate(text: "after-finish")))
        releaseContinuation.yield(())
        releaseContinuation.finish()

        // Absence assertion: a short fixed grace period is fine here (it can only false-pass on a
        // slow machine, never false-fail).
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await recorder.snapshot() == ["delivered"])
    }

    @Test func coalescingKeepsLatestPayloadWithoutReordering() async {
        let recorder = Recorder()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        let gate = OneShotGate()
        let lane = OutboundLane<AnyMessage>(sink: { message in
            await recorder.append(Self.label(message))
            if await gate.first() {
                var it = release.makeAsyncIterator()
                _ = await it.next()
            }
        })

        // First message holds the drain, so the rest queue up and coalesce deterministically.
        lane.enqueue(.clipboardUpdate(ClipboardUpdate(text: "head")))
        for _ in 0..<500 {
            if await recorder.count() == 1 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        lane.enqueue(.cursorPosition(CursorPosition(normalizedX: 0.1, normalizedY: 0)), coalescing: .cursorPosition)
        lane.enqueue(.clipboardUpdate(ClipboardUpdate(text: "middle")))
        lane.enqueue(.cursorPosition(CursorPosition(normalizedX: 0.9, normalizedY: 0)), coalescing: .cursorPosition)
        releaseContinuation.yield(())
        releaseContinuation.finish()

        for _ in 0..<500 {
            if await recorder.count() == 3 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        // The coalesced cursor keeps its original queue position with the LATEST payload.
        let expectedNX = CursorPosition(normalizedX: 0.9, normalizedY: 0).nx
        #expect(await recorder.snapshot() == ["head", "cursor:\(expectedNX)", "middle"])
        lane.finish()
    }

    @Test func sendSuspendsUntilTheSinkHasRun() async {
        // The back-pressure primitive: send() must not return before the sink ran for its message
        // (one chunk in flight at a time is what keeps file transfers from head-of-line blocking
        // control messages).
        let recorder = Recorder()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        let gate = OneShotGate()
        let lane = OutboundLane<AnyMessage>(sink: { message in
            if await gate.first() {
                var it = release.makeAsyncIterator()
                _ = await it.next()
            }
            await recorder.append(Self.label(message))
        })

        let returned = Recorder()
        Task {
            await lane.send(.clipboardUpdate(ClipboardUpdate(text: "held")))
            await returned.append("send-returned")
        }

        // While the sink is held, send() must still be suspended.
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await returned.snapshot() == [])

        releaseContinuation.yield(())
        releaseContinuation.finish()
        for _ in 0..<500 {
            if await returned.count() == 1 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await returned.snapshot() == ["send-returned"])
        #expect(await recorder.snapshot() == ["held"])
        lane.finish()
    }

    @Test func finishReleasesAwaitingSendsWithoutDelivering() async {
        // A sender awaiting back-pressure must never hang on a torn-down lane — finish() resumes
        // it, and its message is dropped.
        let recorder = Recorder()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        let gate = OneShotGate()
        let lane = OutboundLane<AnyMessage>(sink: { message in
            await recorder.append(Self.label(message))
            if await gate.first() {
                var it = release.makeAsyncIterator()
                _ = await it.next()
            }
        })

        lane.enqueue(.clipboardUpdate(ClipboardUpdate(text: "holds-the-drain")))
        for _ in 0..<500 {
            if await recorder.count() == 1 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        let returned = Recorder()
        Task {
            await lane.send(.clipboardUpdate(ClipboardUpdate(text: "never-delivered")))
            await returned.append("released")
        }
        try? await Task.sleep(for: .milliseconds(100))  // let the send reach the queue

        lane.finish()
        releaseContinuation.yield(())
        releaseContinuation.finish()

        for _ in 0..<500 {
            if await returned.count() == 1 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await returned.snapshot() == ["released"])
        #expect(await recorder.snapshot() == ["holds-the-drain"])
    }
}

/// Returns true exactly once — lets a test sink hold only the first drain iteration.
private actor OneShotGate {
    private var fired = false
    func first() -> Bool {
        if fired { return false }
        fired = true
        return true
    }
}

// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import CoreGraphics
import PortviewProtocol
@testable import PortviewHostCore

/// Host-side authority over input injection: while `paused`, `handle(_:)` must be a no-op for
/// every input message type regardless of what a client sends — this is the ONLY gate that can't
/// be bypassed by a modified/hostile client (the existing client-side gate is UX only).
///
/// Asserted at the `postEvent` boundary with real posting stubbed out. A test must NEVER let the
/// default posting run: under an Accessibility-granted parent process, real CGEvents land in
/// whatever app has focus on the dev machine (this suite once typed "hi"+Return into a live app).
@Suite struct InputInjectorGateTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
        func increment() { lock.lock(); _count += 1; lock.unlock() }
    }

    /// Lock-guarded flag box for observing state mutated from a background thread (mirrors
    /// `SessionCapabilityTests.Flag`).
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
        var current: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static let messages: [AnyMessage] = [
        .pointerMove(PointerMove(dx: 1, dy: 1)),
        .pointerButton(PointerButton(button: .left, isDown: true)),
        .scroll(Scroll(dx: 1, dy: 1)),
        .typeText(TypeText(text: "hi")),
        .keyEvent(KeyEvent(special: .returnKey)),
    ]

    @Test func pausedDropsAllMessageKindsThenUnpausedInjectsAll() {
        let injector = InputInjector(displayBounds: CGRect(x: 0, y: 0, width: 1000, height: 1000), capability: SessionCapability())
        let counter = Counter()
        injector.postEvent = { _ in counter.increment() }

        injector.paused = true
        for message in Self.messages { injector.handle(message) }
        #expect(counter.count == 0)

        injector.paused = false
        for message in Self.messages {
            let before = counter.count
            injector.handle(message)
            #expect(counter.count > before, "expected \(message) to post at least one event")
        }
    }

    /// han.4 Task 5 "Bounded-wait" (design §4.1/§4-residual/§8, H-b): every CGEvent post routes
    /// through `capability.perform` INDIVIDUALLY — never the whole `.typeText` message — so
    /// `invalidate()` is checked atomically with each event, not once for the whole compound
    /// message. Proven with real cross-thread contention (mirrors
    /// `SessionCapabilityTests.invalidateMarksAtOnceButItsDrainCannotReturnMidEffect`): the first
    /// `postEvent` call parks inside `perform`'s EFFECT lock, and `invalidate()` is confirmed
    /// BLOCKED (cannot complete) while it's parked — its mark has already landed on the separate
    /// flag lock, but its DRAIN is queued on the effect lock, so it returns only once that one
    /// event's effect finishes. Every later event in the message then observes the mark — at the
    /// fast path or at the re-check under the lock — and posts nothing. Exactly which iteration
    /// observes it first is a genuine OS scheduling
    /// race (the design's own defined residual — §10 R2/R8: "one irreducible effect" may still be
    /// in flight around an invalidation), so this asserts a generous bound, not an exact count —
    /// what matters for H-b is that the gate stops WELL short of the whole 10,000-event message,
    /// not that it stops at exactly the first.
    @Test func typeTextGatedPerCGEventBoundsInvalidateToAHandfulOfEvents() {
        let capability = SessionCapability()
        let injector = InputInjector(displayBounds: CGRect(x: 0, y: 0, width: 1000, height: 1000), capability: capability)
        let counter = Counter()
        let enteredFirstEvent = DispatchSemaphore(value: 0)
        let releaseFirstEvent = DispatchSemaphore(value: 0)
        let totalEvents = 5_000 * 2  // .typeText posts 2 CGEvents/char

        injector.postEvent = { _ in
            counter.increment()
            if counter.count == 1 {
                enteredFirstEvent.signal()
                releaseFirstEvent.wait()
            }
        }

        let group = DispatchGroup()
        group.enter()
        Thread.detachNewThread {
            // 5,000 characters × 2 CGEvents/char — if the gate ever wrapped the whole message
            // instead of each event, every one of these would post regardless of invalidate.
            injector.handle(.typeText(TypeText(text: String(repeating: "a", count: 5_000))))
            group.leave()
        }

        #expect(enteredFirstEvent.wait(timeout: .now() + 10) == .success)

        // invalidate()'s DRAIN must block on the same effect lock the parked first `perform` call
        // holds — it cannot complete until that call returns, proving the injection path is
        // drain-coupled here too (not just in SessionCapabilityTests' own unit test). Its mark, on
        // the separate flag lock, has already landed by then.
        let invalidateCompleted = Flag()
        let invalidateGroup = DispatchGroup()
        invalidateGroup.enter()
        Thread.detachNewThread {
            capability.invalidate()
            invalidateCompleted.set(true)
            invalidateGroup.leave()
        }

        // Bounded window for invalidate() to mark and then block in its drain. The mark is already
        // visible while the first event is still parked; invalidate() itself must NOT have returned.
        Thread.sleep(forTimeInterval: 0.05)
        #expect(capability.isValid == false)
        #expect(invalidateCompleted.current == false)

        releaseFirstEvent.signal()
        #expect(invalidateGroup.wait(timeout: .now() + 10) == .success)
        #expect(group.wait(timeout: .now() + 10) == .success)

        #expect(counter.count >= 1)
        #expect(
            counter.count < totalEvents / 10,
            "invalidate() must cut the large .typeText off far short of its \(totalEvents) events (posted \(counter.count)) — the gate must be per-CGEvent, not whole-message"
        )
    }
}

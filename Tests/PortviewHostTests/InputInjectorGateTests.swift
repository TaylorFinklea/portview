import Testing
import Foundation
import CoreGraphics
import PortviewProtocol
@testable import PortviewHostCore

/// Host-side authority over input injection: while `paused`, `handle(_:)` must be a no-op for
/// every input message type regardless of what a client sends — this is the ONLY gate that can't
/// be bypassed by a modified/hostile client (the existing client-side gate is UX only).
@Suite struct InputInjectorGateTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
        func increment() { lock.lock(); _count += 1; lock.unlock() }
    }

    private static let messages: [AnyMessage] = [
        .pointerMove(PointerMove(dx: 1, dy: 1)),
        .pointerButton(PointerButton(button: .left, isDown: true)),
        .scroll(Scroll(dx: 1, dy: 1)),
        .typeText(TypeText(text: "hi")),
        .keyEvent(KeyEvent(special: .returnKey)),
    ]

    @Test func pausedDropsAllMessageKindsThenUnpausedInjectsAll() {
        let injector = InputInjector(displayBounds: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let counter = Counter()
        injector.didInject = { counter.increment() }

        injector.paused = true
        for message in Self.messages { injector.handle(message) }
        #expect(counter.count == 0)

        injector.paused = false
        for message in Self.messages { injector.handle(message) }
        #expect(counter.count == Self.messages.count)
    }
}

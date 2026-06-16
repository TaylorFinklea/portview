import XCTest
import PortviewProtocol

@testable import PortviewClient

/// The ordered outbound lane: discrete events keep their order; consecutive pointer-moves coalesce
/// but preserve total delta (so the cursor can't lurch through a backlog of stale moves).
@MainActor
final class OutboundInputPumpTests: XCTestCase {
    private actor Tags {
        private(set) var values: [String] = []
        func append(_ tag: String) { values.append(tag) }
        func count() -> Int { values.count }
        func snapshot() -> [String] { values }
    }

    private actor Delta {
        private(set) var sum: Int32 = 0
        func add(_ dx: Int32) { sum += dx }
        func value() -> Int32 { sum }
    }

    private static func tag(_ message: AnyMessage) -> String {
        switch message {
        case .pointerButton(let button): return button.isDown ? "down" : "up"
        case .scroll: return "scroll"
        case .pointerMove: return "move"
        default: return "other"
        }
    }

    func testDiscreteEventsPreserveOrder() async {
        let tags = Tags()
        let pump = OutboundInputPump(sink: { message in await tags.append(Self.tag(message)) })
        pump.enqueue(.pointerButton(PointerButton(button: .left, isDown: true)))
        pump.enqueue(.pointerButton(PointerButton(button: .left, isDown: false)))
        pump.enqueue(.scroll(Scroll(dx: 0, dy: 3)))

        for _ in 0..<200 {
            let n = await tags.count()
            if n >= 3 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let received = await tags.snapshot()
        XCTAssertEqual(received, ["down", "up", "scroll"])
    }

    func testConsecutiveMovesCoalescePreservingTotalDelta() async {
        let delta = Delta()
        let pump = OutboundInputPump(sink: { message in
            if case .pointerMove(let move) = message { await delta.add(move.dx) }
        })

        let total: Int32 = 300
        for _ in 0..<total { pump.enqueue(.pointerMove(PointerMove(dx: 1, dy: 0))) }

        for _ in 0..<200 {
            let sum = await delta.value()
            if sum >= total { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        // Coalescing collapses messages but must never lose movement: the summed delta is exact.
        let finalSum = await delta.value()
        XCTAssertEqual(finalSum, total)
    }
}

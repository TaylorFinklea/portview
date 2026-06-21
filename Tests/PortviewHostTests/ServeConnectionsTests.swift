import Testing
import Foundation
@testable import PortviewHostCore

/// Guardrail C: the connection serve loop bounds how many connections it serves concurrently, so a
/// flood (or many ~25s-lingering SAS preambles) can't spawn unbounded tasks — excess connections
/// queue (backpressure) instead.
@Suite struct ServeConnectionsTests {
    private actor Tracker {
        private(set) var current = 0
        private(set) var peak = 0
        private(set) var total = 0
        func enter() { current += 1; peak = max(peak, current) }
        func leave() { current -= 1; total += 1 }
    }

    @Test func neverExceedsTheConcurrencyCap() async {
        let tracker = Tracker()
        let (stream, cont) = AsyncStream<Int>.makeStream()
        for i in 0..<20 { cont.yield(i) }
        cont.finish()

        await HostRunner.serveConnections(stream, maxConcurrent: 4) { _ in
            await tracker.enter()
            try? await Task.sleep(for: .milliseconds(15))  // force overlap so an uncapped loop would peak at 20
            await tracker.leave()
        }

        #expect(await tracker.peak <= 4)   // the cap holds
        #expect(await tracker.total == 20) // and every connection is still served (no drops)
    }

    @Test func capOfOneSerializesStrictly() async {
        let tracker = Tracker()
        let (stream, cont) = AsyncStream<Int>.makeStream()
        for i in 0..<6 { cont.yield(i) }
        cont.finish()

        await HostRunner.serveConnections(stream, maxConcurrent: 1) { _ in
            await tracker.enter()
            try? await Task.sleep(for: .milliseconds(5))
            await tracker.leave()
        }

        #expect(await tracker.peak == 1)   // strictly one at a time
        #expect(await tracker.total == 6)
    }
}

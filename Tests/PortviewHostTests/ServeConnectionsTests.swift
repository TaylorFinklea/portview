// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
@testable import PortviewHostCore
@testable import PortviewProtocol

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

    /// Regression for the serve-cap starvation threat: many connections whose serve closure never
    /// completes on its own (phantom/slow-loris — modeling QUIC double-delivery or a stalled client
    /// that never sends its first message) queue up against `maxConcurrent`. Without a first-message
    /// deadline, a legit data-carrying connection queued behind them would never get served. With
    /// `HostRunner.MessageReader`'s deadline racing the read, each phantom's slot frees after the
    /// deadline elapses, so the data connection is served within a bounded time instead of starving.
    @Test(.timeLimit(.minutes(3))) func deadlineFreesPhantomSlotsSoDataConnectionIsNotStarved() async {
        let phantomCount = 12
        let maxConcurrent = 4
        let deadline = Duration.milliseconds(20)

        // Phantom connections: an AsyncStream<AnyMessage> that never yields anything (simulates an
        // idle/slow-loris client, or a QUIC stream that never delivers its first message).
        @Sendable func phantomStream() -> AsyncStream<AnyMessage> {
            AsyncStream<AnyMessage> { _ in }
        }
        // The legit connection: yields a message immediately.
        @Sendable func dataStream() -> AsyncStream<AnyMessage> {
            let (stream, cont) = AsyncStream<AnyMessage>.makeStream()
            cont.yield(.bye(Bye(reason: "hello")))
            cont.finish()
            return stream
        }

        let servedData = ManagedAtomic()

        let (connections, cont) = AsyncStream<Bool>.makeStream()
        for _ in 0..<phantomCount { cont.yield(false) }
        cont.yield(true) // the data connection queues behind every phantom
        cont.finish()

        let start = ContinuousClock.now
        await HostRunner.serveConnections(connections, maxConcurrent: maxConcurrent) { isDataConnection in
            let inbound = HostRunner.MessageReader(isDataConnection ? dataStream() : phantomStream())
            let message = await inbound.next(deadline: deadline)
            if isDataConnection, message != nil {
                await servedData.markServed(elapsed: ContinuousClock.now - start)
            }
        }

        let elapsed = await servedData.served
        // The data connection was in fact served — not dropped, and not starved indefinitely behind
        // the phantoms (without the deadline it would never complete: the .timeLimit trait above
        // would fail the test on a true hang). We don't assert a tight multiple of `deadline` here
        // since a fully-loaded test run (many suites' real crypto/network work sharing the
        // cooperative thread pool) can push actual wall-clock delays well past nominal sleep
        // durations without that indicating a starvation regression.
        #expect(elapsed != nil)
    }

    private actor ManagedAtomic {
        private(set) var served: Duration?
        func markServed(elapsed: Duration) { served = elapsed }
    }
}

import Testing
import Foundation
@testable import PortviewHostCore
import PortviewProtocol

/// The first-message read on a serve path (`serveSession`, `serveSASPreamble`) previously had no
/// application-level bound — only the 30s QUIC idle timeout capped it, letting an idle/phantom
/// connection hold a serve-cap slot for the full ~30s. `HostRunner.MessageReader` owns the
/// connection's inbound iterator and races each read against a deadline so a silent peer's slot
/// frees quickly instead.
@Suite struct HandshakeDeadlineTests {
    @Test func returnsNilWhenNoMessageArrivesWithinDeadline() async {
        let (stream, _) = AsyncStream<AnyMessage>.makeStream()
        let inbound = HostRunner.MessageReader(stream)

        let result = await inbound.next(deadline: .milliseconds(50))

        #expect(result == nil)
    }

    @Test func returnsTheMessageWhenOneArrivesBeforeTheDeadline() async {
        let (stream, continuation) = AsyncStream<AnyMessage>.makeStream()
        continuation.yield(.bye(Bye(reason: "hello")))
        let inbound = HostRunner.MessageReader(stream)

        let result = await inbound.next(deadline: .seconds(5))

        #expect(result == .bye(Bye(reason: "hello")))
    }

    /// The timeout path must not race (or abandon) the still-in-flight background read: a message
    /// that arrives AFTER a timeout belongs to the NEXT read, deterministically — not to a leaked
    /// background task that consumes and drops it. The second read is deadline-bounded so a
    /// regression fails (returns nil) instead of wedging the suite.
    @Test(.timeLimit(.minutes(1))) func lateMessageAfterATimeoutIsDeliveredToTheNextRead() async {
        let (stream, continuation) = AsyncStream<AnyMessage>.makeStream()
        let inbound = HostRunner.MessageReader(stream)

        let first = await inbound.next(deadline: .milliseconds(20))
        #expect(first == nil)  // nothing yielded yet — the deadline fires

        continuation.yield(.bye(Bye(reason: "late")))
        let second = await inbound.next(deadline: .seconds(5))
        #expect(second == .bye(Bye(reason: "late")))
    }

    /// Same guarantee for the undeadlined read that the session loop uses after the peek: it picks
    /// up the read left pending by a timed-out peek instead of double-consuming the stream.
    @Test(.timeLimit(.minutes(1))) func undeadlinedNextReusesTheReadLeftPendingByATimeout() async {
        let (stream, continuation) = AsyncStream<AnyMessage>.makeStream()
        let inbound = HostRunner.MessageReader(stream)

        let first = await inbound.next(deadline: .milliseconds(20))
        #expect(first == nil)

        continuation.yield(.bye(Bye(reason: "late")))
        continuation.finish()
        let second = await inbound.next()
        #expect(second == .bye(Bye(reason: "late")))
        let third = await inbound.next()
        #expect(third == nil)  // stream ended — subsequent reads settle nil, they don't wedge
    }

    /// Sequential reads through the reader see every message in order (the peek-then-loop path:
    /// `serveSession` peeks the first message with a deadline, then keeps reading).
    @Test func sequentialReadsAfterASuccessfulPeekStayInOrder() async {
        let (stream, continuation) = AsyncStream<AnyMessage>.makeStream()
        continuation.yield(.bye(Bye(reason: "first")))
        continuation.yield(.bye(Bye(reason: "second")))
        continuation.finish()
        let inbound = HostRunner.MessageReader(stream)

        let first = await inbound.next(deadline: .seconds(5))
        let second = await inbound.next()
        let third = await inbound.next()

        #expect(first == .bye(Bye(reason: "first")))
        #expect(second == .bye(Bye(reason: "second")))
        #expect(third == nil)
    }
}

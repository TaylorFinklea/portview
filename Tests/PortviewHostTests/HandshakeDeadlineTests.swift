import Testing
import Foundation
@testable import PortviewHostCore
import PortviewProtocol

/// The first-message read on a serve path (`serveSession`, `serveSASPreamble`) previously had no
/// application-level bound — only the 30s QUIC idle timeout capped it, letting an idle/phantom
/// connection hold a serve-cap slot for the full ~30s. `HostRunner.nextMessage` races the inbound
/// read against a deadline so a silent peer's slot frees quickly instead.
@Suite struct HandshakeDeadlineTests {
    @Test func returnsNilWhenNoMessageArrivesWithinDeadline() async {
        let (stream, _) = AsyncStream<AnyMessage>.makeStream()
        var iterator = stream.makeAsyncIterator()

        let result = await HostRunner.nextMessage(from: &iterator, deadline: .milliseconds(50))

        #expect(result == nil)
    }

    @Test func returnsTheMessageWhenOneArrivesBeforeTheDeadline() async {
        let (stream, continuation) = AsyncStream<AnyMessage>.makeStream()
        continuation.yield(.bye(Bye(reason: "hello")))
        var iterator = stream.makeAsyncIterator()

        let result = await HostRunner.nextMessage(from: &iterator, deadline: .seconds(5))

        #expect(result == .bye(Bye(reason: "hello")))
    }
}

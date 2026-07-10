// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import PortviewTransport
@testable import PortviewProtocol

@Suite struct MessageChannelTests {
    @Test func encodesOutboundMessageToFrameBytes() {
        let channel = MessageChannel()
        let bytes = channel.outbound(.bye(Bye(reason: "x")))
        #expect(bytes == Frame.encodeAny(.bye(Bye(reason: "x"))))
    }

    @Test func reassemblesInboundBytesIntoMessages() throws {
        var channel = MessageChannel()
        let a = Frame.encodeAny(.bye(Bye(reason: "a")))
        let b = Frame.encodeAny(.bye(Bye(reason: "b")))
        let combined = a + b
        let firstHalf = Array(combined[0..<(a.count - 1)])
        let rest = Array(combined[(a.count - 1)...])
        #expect(try channel.inbound(firstHalf).isEmpty)            // a not yet complete
        #expect(try channel.inbound(rest) == [.bye(Bye(reason: "a")), .bye(Bye(reason: "b"))])
    }
}

// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import PortviewProtocol

@Suite struct SwitchDisplayTests {
    @Test func switchDisplayRoundTrips() throws {
        let message = SwitchDisplay(displayID: 0x1234_5678)
        var w = BinaryWriter()
        message.encode(into: &w)
        var r = BinaryReader(w.bytes)
        #expect(try SwitchDisplay(from: &r) == message)
        #expect(SwitchDisplay.messageType == .switchDisplay)
    }

    @Test func switchDisplayThroughFrame() throws {
        let any: AnyMessage = .switchDisplay(SwitchDisplay(displayID: 7))
        #expect(try Frame.decode(Frame.encodeAny(any)) == any)
    }
}

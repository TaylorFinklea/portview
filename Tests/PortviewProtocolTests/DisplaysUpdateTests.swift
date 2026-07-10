// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import PortviewProtocol

@Suite struct DisplaysUpdateTests {
    @Test func displaysUpdateRoundTrips() throws {
        let message = DisplaysUpdate(displays: [
            DisplayInfo(id: 1, name: "Built-in", width: 3456, height: 2234, scaleX100: 200),
            DisplayInfo(id: 2, name: "Studio Display", width: 5120, height: 2880, scaleX100: 200),
        ])
        var w = BinaryWriter()
        message.encode(into: &w)
        var r = BinaryReader(w.bytes)
        #expect(try DisplaysUpdate(from: &r) == message)
        #expect(DisplaysUpdate.messageType == .displaysUpdate)
    }

    @Test func displaysUpdateThroughFrame() throws {
        let any: AnyMessage = .displaysUpdate(DisplaysUpdate(displays: [
            DisplayInfo(id: 7, name: "Display 7", width: 1920, height: 1080, scaleX100: 100),
        ]))
        #expect(try Frame.decode(Frame.encodeAny(any)) == any)
    }

    @Test func emptyDisplaysUpdateRoundTrips() throws {
        let message = DisplaysUpdate(displays: [])
        var w = BinaryWriter()
        message.encode(into: &w)
        var r = BinaryReader(w.bytes)
        #expect(try DisplaysUpdate(from: &r) == message)
    }
}

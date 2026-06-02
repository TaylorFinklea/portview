import Testing
@testable import PortviewProtocol

@Suite struct ClipboardMessageTests {
    @Test func clipboardUpdateRoundTrips() throws {
        let message = ClipboardUpdate(text: "copied text 🪟\nline 2")
        var w = BinaryWriter()
        message.encode(into: &w)
        var r = BinaryReader(w.bytes)
        #expect(try ClipboardUpdate(from: &r) == message)
        #expect(ClipboardUpdate.messageType == .clipboardUpdate)
    }

    @Test func clipboardUpdateThroughFrame() throws {
        let any: AnyMessage = .clipboardUpdate(ClipboardUpdate(text: "hi"))
        #expect(try Frame.decode(Frame.encodeAny(any)) == any)
    }
}

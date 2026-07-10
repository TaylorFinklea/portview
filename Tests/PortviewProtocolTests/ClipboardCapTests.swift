// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import PortviewProtocol

/// The wire ceiling `Frame.maxBodyLength` (16 MiB) means a `.clipboardUpdate` payload above it makes
/// the receiving decoder throw `WireError.malformed` and drop the connection. Senders on BOTH sides
/// gate outbound clipboard on `Frame.shouldSendClipboard`; these pin the pure cap decision at the
/// boundary so a huge copy can never kill the session.
@Suite struct ClipboardCapTests {
    @Test func acceptsTextExactlyAtCap() {
        let atCap = String(repeating: "a", count: Frame.maxClipboardBytes)
        #expect(atCap.utf8.count == Frame.maxClipboardBytes)
        #expect(Frame.shouldSendClipboard(atCap) == true)
    }

    @Test func rejectsTextOneByteOverCap() {
        let overCap = String(repeating: "a", count: Frame.maxClipboardBytes + 1)
        #expect(Frame.shouldSendClipboard(overCap) == false)
    }

    @Test func normalClipboardTextIsSent() {
        #expect(Frame.shouldSendClipboard("hello") == true)
        #expect(Frame.shouldSendClipboard("") == true)
    }

    @Test func capSitsWellUnderMaxBodyLength() {
        #expect(UInt64(Frame.maxClipboardBytes) < Frame.maxBodyLength)
    }
}

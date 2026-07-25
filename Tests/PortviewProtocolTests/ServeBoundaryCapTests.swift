// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import PortviewProtocol

/// Serve-boundary size caps (han.4 Task 8, design §4 H-b). Every privileged inbound message is
/// size-capped BEFORE dispatch so the COUNT of irreducible OS effects an attacker can queue per
/// message is bounded — this keeps a revoke's `SessionCapability.invalidate()` from being starved by
/// one giant message. These pin the pure cap decisions the serve loop gates on; the `.clipboardUpdate`
/// cap reuses `Frame.shouldSendClipboard` (covered by `ClipboardCapTests`).
@Suite struct ServeBoundaryCapTests {
    // MARK: .typeText

    @Test func typeTextAcceptedExactlyAtCap() {
        let atCap = String(repeating: "a", count: Frame.maxTypeTextBytes)
        #expect(atCap.utf8.count == Frame.maxTypeTextBytes)
        #expect(Frame.shouldInjectTypeText(atCap) == true)
    }

    @Test func typeTextRejectedOneByteOverCap() {
        let overCap = String(repeating: "a", count: Frame.maxTypeTextBytes + 1)
        #expect(Frame.shouldInjectTypeText(overCap) == false)
    }

    @Test func normalTypeTextIsInjected() {
        #expect(Frame.shouldInjectTypeText("hello world") == true)
        #expect(Frame.shouldInjectTypeText("") == true)
    }

    @Test func typeTextCapSitsWellUnderMaxBodyLength() {
        #expect(UInt64(Frame.maxTypeTextBytes) < Frame.maxBodyLength)
    }

    // MARK: .fileChunk

    @Test func fileChunkAcceptedExactlyAtCap() {
        let atCap = FileChunk(transferID: 1, isLast: false, data: [UInt8](repeating: 0, count: Frame.maxFileChunkBytes))
        #expect(Frame.shouldWriteFileChunk(atCap) == true)
    }

    @Test func fileChunkRejectedOneByteOverCap() {
        let overCap = FileChunk(transferID: 1, isLast: false, data: [UInt8](repeating: 0, count: Frame.maxFileChunkBytes + 1))
        #expect(Frame.shouldWriteFileChunk(overCap) == false)
    }

    @Test func senderChunkSizePasses() {
        // The sender (SessionViewModel/HostControl) slices at 64 KiB — a legitimate chunk must pass.
        let senderChunk = FileChunk(transferID: 1, isLast: false, data: [UInt8](repeating: 0, count: 64 * 1024))
        #expect(Frame.shouldWriteFileChunk(senderChunk) == true)
        #expect(Frame.maxFileChunkBytes >= 64 * 1024)  // headroom over the sender's chunk
    }

    @Test func fileChunkCapSitsWellUnderMaxBodyLength() {
        #expect(UInt64(Frame.maxFileChunkBytes) < Frame.maxBodyLength)
    }
}

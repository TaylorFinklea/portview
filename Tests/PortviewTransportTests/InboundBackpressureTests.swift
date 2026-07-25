// SPDX-License-Identifier: Apache-2.0
import Foundation
import Network
import Testing
import PortviewProtocol
@testable import PortviewTransport

/// Drives `processIncoming` directly (no live socket) to pin the connection-level backpressure
/// behavior: a stalled consumer can no longer grow memory without bound.
@Suite struct InboundBackpressureTests {
    private func makeConnection() -> PortviewConnection {
        // Never started — processIncoming is driven directly.
        let nw = NWConnection(to: .hostPort(host: "127.0.0.1", port: 1), using: .udp)
        return PortviewConnection(connection: nw, queue: DispatchQueue(label: "test"))
    }

    private func videoFrameBytes(_ sequence: UInt64) -> [UInt8] {
        Frame.encode(VideoFrame(sequence: sequence, ptsMicros: sequence, isKeyframe: false,
                                displayID: 0, width: 1, height: 1, data: [1, 2, 3]))
    }

    @Test func stalledConsumerHoldsAtMostTwoVideoFrames() {
        let connection = makeConnection()
        for sequence in 1...50 {
            #expect(connection.processIncoming(videoFrameBytes(UInt64(sequence))))
        }
        #expect(connection.inboundBuffer.videoFramesBuffered == 2)
        #expect(connection.inboundBuffer.droppedVideoFrames == 48)
    }

    @Test func controlFloodPausesReceiveAndConsumerResumesIt() async {
        let connection = makeConnection()
        // 70 file chunks × 64 KiB ≈ 4.4 MiB > the 4 MiB high water.
        let chunk = FileChunk(transferID: 1, isLast: false, data: [UInt8](repeating: 0, count: 64 * 1024))
        var paused = false
        for _ in 0..<70 {
            #expect(connection.processIncoming(Frame.encode(chunk)))
            if connection.inboundBuffer.isReceivePaused { paused = true }
        }
        #expect(paused, "the control flood must cross the high water and pause receive")

        // Drain like a recovered consumer: the stream must deliver every chunk (lossless) and
        // eventually clear the pause once below the low water.
        var received = 0
        for await message in connection.inbound {
            guard case .fileChunk = message else { break }
            received += 1
            if received == 70 { break }
        }
        #expect(received == 70)
        #expect(!connection.inboundBuffer.isReceivePaused)
    }

    @Test func decodeErrorStillFinishesTheStream() async {
        let connection = makeConnection()
        // An over-ceiling declared frame length is malformed (wire-hardening bead 1n6.1).
        var writer = BinaryWriter()
        writer.putVarUInt(Frame.maxBodyLength + 1)
        #expect(!connection.processIncoming(writer.bytes))
        var sawEnd = false
        for await _ in connection.inbound { }
        sawEnd = true
        #expect(sawEnd)
    }

    // MARK: - closeDiscardingInbound (han.4 finding 7 — discard-not-drain)

    /// Buffered-but-undelivered control messages must be DISCARDED, not drained, on a
    /// discard-close: `inbound` ends immediately without ever yielding them. This is the
    /// security-critical case — a revoked peer's queued `.typeText`/clipboard/file frames.
    @Test func closeDiscardingInboundDropsAlreadyBufferedMessagesInsteadOfDeliveringThem() async {
        let connection = makeConnection()
        let queuedText = TypeText(text: "attacker-queued-keystrokes")
        #expect(connection.processIncoming(Frame.encode(queuedText)))
        #expect(connection.inboundBuffer.controlBytesBuffered > 0)

        connection.closeDiscardingInbound()

        #expect(connection.inboundBuffer.controlBytesBuffered == 0)
        var received: [AnyMessage] = []
        for await message in connection.inbound { received.append(message) }
        #expect(received.isEmpty)
    }

    /// A receive callback that decodes successfully AFTER a discard-close (racing it, or simply
    /// arriving late) must be rejected as `.droppedFinished` — never appended, and never able to
    /// resurrect the already-finished `inbound` stream (finding 7's terminal-verdict fix).
    @Test func aReceiveCallbackRacingCloseDiscardingInboundNeverResurrectsTheStream() async {
        let connection = makeConnection()
        connection.closeDiscardingInbound()

        // Simulate the racing/late receive callback's decode: it succeeds (not a decode error)...
        #expect(connection.processIncoming(Frame.encode(TypeText(text: "post-revoke"))))
        // ...but the underlying enqueue is the terminal verdict, not a silent append.
        #expect(connection.inboundBuffer.enqueue([.bye(Bye(reason: "also-post-revoke"))]) == .droppedFinished)

        var received: [AnyMessage] = []
        for await message in connection.inbound { received.append(message) }
        #expect(received.isEmpty)
    }
}

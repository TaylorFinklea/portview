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
}

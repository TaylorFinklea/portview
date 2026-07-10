// SPDX-License-Identifier: Apache-2.0
/// Client → host receive-side quality feedback, sent periodically off the client's 1s diagnostics
/// snapshot so a host-side quality controller can adapt the stream. Scaled integer fields keep the
/// wire format deterministic: fps/Mbps/ms values are encoded as value × 100. `rttMicros` is the
/// latest Ping/Pong round-trip time in microseconds (0 = not yet measured).
public struct ClientFeedback: WireMessage, Equatable, Sendable {
    public static let messageType = MessageType.clientFeedback

    public var receivedFPSX100: UInt32
    public var receivedMbpsX100: UInt32
    public var averageDecodeMsX100: UInt32
    public var decodeQueueDepth: UInt16
    public var droppedFrames: UInt32
    public var rttMicros: UInt32

    public init(
        receivedFPSX100: UInt32,
        receivedMbpsX100: UInt32,
        averageDecodeMsX100: UInt32,
        decodeQueueDepth: UInt16,
        droppedFrames: UInt32,
        rttMicros: UInt32
    ) {
        self.receivedFPSX100 = receivedFPSX100
        self.receivedMbpsX100 = receivedMbpsX100
        self.averageDecodeMsX100 = averageDecodeMsX100
        self.decodeQueueDepth = decodeQueueDepth
        self.droppedFrames = droppedFrames
        self.rttMicros = rttMicros
    }

    public var receivedFPS: Double { Double(receivedFPSX100) / 100.0 }
    public var receivedMbps: Double { Double(receivedMbpsX100) / 100.0 }
    public var averageDecodeMs: Double { Double(averageDecodeMsX100) / 100.0 }

    public func encode(into writer: inout BinaryWriter) {
        writer.putUInt32(receivedFPSX100)
        writer.putUInt32(receivedMbpsX100)
        writer.putUInt32(averageDecodeMsX100)
        writer.putUInt16(decodeQueueDepth)
        writer.putUInt32(droppedFrames)
        writer.putUInt32(rttMicros)
    }

    public init(from reader: inout BinaryReader) throws {
        receivedFPSX100 = try reader.uint32()
        receivedMbpsX100 = try reader.uint32()
        averageDecodeMsX100 = try reader.uint32()
        decodeQueueDepth = try reader.uint16()
        droppedFrames = try reader.uint32()
        rttMicros = try reader.uint32()
    }
}

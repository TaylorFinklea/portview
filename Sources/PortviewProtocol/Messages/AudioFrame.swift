// SPDX-License-Identifier: Apache-2.0
/// Host → client. One slice of system audio as non-interleaved Float32 PCM (plane 0 then
/// plane 1 …). `channels` planes of equal length make up `data`.
public struct AudioFrame: WireMessage, Equatable {
    public static let messageType = MessageType.audioFrame
    public var sampleRate: UInt32
    public var channels: UInt8
    public var ptsMicros: UInt64
    public var data: [UInt8]

    public init(sampleRate: UInt32, channels: UInt8, ptsMicros: UInt64, data: [UInt8]) {
        self.sampleRate = sampleRate; self.channels = channels
        self.ptsMicros = ptsMicros; self.data = data
    }

    public func encode(into w: inout BinaryWriter) {
        w.putUInt32(sampleRate)
        w.putUInt8(channels)
        w.putUInt64(ptsMicros)
        w.putData(data)
    }

    public init(from r: inout BinaryReader) throws {
        sampleRate = try r.uint32()
        channels = try r.uint8()
        ptsMicros = try r.uint64()
        data = try r.data()
    }
}

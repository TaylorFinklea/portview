// SPDX-License-Identifier: Apache-2.0
/// Host → client. Echoes the `Ping.sendMicros` the host received, plus the host's own monotonic
/// uptime (microseconds) at reply time, so the client can compute RTT (from the echoed send time)
/// and an approximate clock offset (from the host uptime reading).
public struct Pong: WireMessage, Equatable {
    public static let messageType = MessageType.pong
    public var sendMicros: UInt64
    public var hostUptimeMicros: UInt64

    public init(sendMicros: UInt64, hostUptimeMicros: UInt64) {
        self.sendMicros = sendMicros
        self.hostUptimeMicros = hostUptimeMicros
    }

    public func encode(into w: inout BinaryWriter) {
        w.putUInt64(sendMicros)
        w.putUInt64(hostUptimeMicros)
    }
    public init(from r: inout BinaryReader) throws {
        sendMicros = try r.uint64()
        hostUptimeMicros = try r.uint64()
    }
}

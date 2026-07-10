// SPDX-License-Identifier: Apache-2.0
/// Client → host. Carries the client's send timestamp (microseconds, client clock) so the host can
/// echo it back in a `Pong`, letting the client derive round-trip time and an approximate clock offset.
public struct Ping: WireMessage, Equatable {
    public static let messageType = MessageType.ping
    public var sendMicros: UInt64

    public init(sendMicros: UInt64) { self.sendMicros = sendMicros }

    public func encode(into w: inout BinaryWriter) { w.putUInt64(sendMicros) }
    public init(from r: inout BinaryReader) throws { sendMicros = try r.uint64() }
}

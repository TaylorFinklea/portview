// SPDX-License-Identifier: Apache-2.0
/// Either side. Graceful session close with a human-readable reason.
public struct Bye: WireMessage {
    public static let messageType = MessageType.bye
    public var reason: String
    public init(reason: String) { self.reason = reason }
    public func encode(into w: inout BinaryWriter) { w.putString(reason) }
    public init(from r: inout BinaryReader) throws { reason = try r.string() }
}

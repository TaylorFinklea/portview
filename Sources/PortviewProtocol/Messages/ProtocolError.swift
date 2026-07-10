// SPDX-License-Identifier: Apache-2.0
/// Either side. A coded error; closes the session.
public struct ProtocolError: WireMessage {
    public static let messageType = MessageType.error
    public var code: UInt16
    public var message: String
    public init(code: UInt16, message: String) { self.code = code; self.message = message }
    public func encode(into w: inout BinaryWriter) { w.putUInt16(code); w.putString(message) }
    public init(from r: inout BinaryReader) throws { code = try r.uint16(); message = try r.string() }
}

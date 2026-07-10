// SPDX-License-Identifier: Apache-2.0
/// Either side. A clipboard text update to mirror onto the peer's pasteboard.
public struct ClipboardUpdate: WireMessage {
    public static let messageType = MessageType.clipboardUpdate
    public var text: String

    public init(text: String) { self.text = text }
    public func encode(into w: inout BinaryWriter) { w.putString(text) }
    public init(from r: inout BinaryReader) throws { text = try r.string() }
}

/// Client → host (SAS pairing preamble). The client's 16-byte nonce, revealed only after both
/// commitments are exchanged. The host verifies it against the earlier `SASClientCommit` before use.
public struct SASClientReveal: WireMessage {
    public static let messageType = MessageType.sasClientReveal
    public var nonce: [UInt8]

    public init(nonce: [UInt8]) { self.nonce = nonce }

    public func encode(into w: inout BinaryWriter) { w.putBytes(nonce) }
    public init(from r: inout BinaryReader) throws { nonce = try r.readBytes(16) }
}

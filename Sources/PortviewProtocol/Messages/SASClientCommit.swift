/// Client → host (SAS pairing preamble). The client's nonce commitment (32 bytes,
/// `SASCode.commit`), sent before any nonce is revealed. First message of the preamble — its arrival
/// locks the connection to the SAS-preamble role (no streaming surface).
public struct SASClientCommit: WireMessage {
    public static let messageType = MessageType.sasClientCommit
    public var commit: [UInt8]

    public init(commit: [UInt8]) { self.commit = commit }

    public func encode(into w: inout BinaryWriter) { w.putBytes(commit) }
    public init(from r: inout BinaryReader) throws { commit = try r.readBytes(32) }
}

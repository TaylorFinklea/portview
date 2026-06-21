/// Client → host (SAS pairing preamble, optional Guardrail E). A 32-byte HMAC the client sends after
/// the user-typed code matched its derived code, so the host gets an authenticated "✓ a client
/// confirmed" signal. Best-effort/defense-in-depth: a client that never sends it still pairs via the
/// pinned re-dial, and the host never gates the session on it. One-directional (client→host only).
public struct SASClientConfirm: WireMessage {
    public static let messageType = MessageType.sasClientConfirm
    public var mac: [UInt8]

    public init(mac: [UInt8]) { self.mac = mac }

    public func encode(into w: inout BinaryWriter) { w.putBytes(mac) }
    public init(from r: inout BinaryReader) throws { mac = try r.readBytes(32) }
}

/// The fixed preamble a client writes once, first, on every secondary QUIC lane stream it opens:
/// `[uint8 laneRawValue][32B sessionToken]`. Pure codec — no I/O. The host reads this preamble to
/// classify the stream (see `Lane`) and to bind it to the session via the token minted in
/// `ServerHello`.
///
/// Per-stream `FrameDecoder` convention: frames never straddle streams. Each QUIC stream
/// (primary, and each lane stream after its preamble) gets its own `FrameDecoder` instance
/// decoding its own self-delimiting byte sequence; a `Frame` decoded on one stream is never
/// completed with bytes read from another. The preamble itself sits outside that convention —
/// it is raw, pre-framing bytes consumed once at stream-open, before a `FrameDecoder` ever sees
/// the stream.
public struct LanePreamble: Equatable, Sendable {
    /// Length in bytes of `sessionToken` on the wire.
    public static let tokenLength = 32

    public var lane: Lane
    public var sessionToken: [UInt8]

    public init(lane: Lane, sessionToken: [UInt8]) {
        self.lane = lane
        self.sessionToken = sessionToken
    }

    /// Encode `[uint8 laneRawValue][32B sessionToken]`.
    public func encode() -> [UInt8] {
        var w = BinaryWriter()
        w.putUInt8(lane.rawValue)
        w.putBytes(sessionToken)
        return w.bytes
    }

    /// Decode a preamble from raw stream bytes. Throws `WireError.unknownEnum` for a lane byte
    /// outside `Lane`'s known cases (caller closes just that stream; session unaffected — the
    /// first-byte classification rule lives in the "Stream classification" section of
    /// `docs/superpowers/specs/2026-07-01-quic-lane-splitting.md`) and `WireError.truncated` if
    /// fewer than `tokenLength` token bytes are available.
    public static func decode(_ bytes: [UInt8]) throws -> LanePreamble {
        var r = BinaryReader(bytes)
        let raw = try r.uint8()
        guard let lane = Lane(rawValue: raw) else {
            throw WireError.unknownEnum("Lane", UInt64(raw))
        }
        let sessionToken = try r.readBytes(tokenLength)
        return LanePreamble(lane: lane, sessionToken: sessionToken)
    }
}

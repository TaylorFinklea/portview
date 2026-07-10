/// Wire-protocol version negotiation.
///
/// Bump rules:
/// 1. ``current`` bumps for ANY wire change (new message, new field, new tag — anything a peer
///    could observe on the wire).
/// 2. ``minimum`` bumps ONLY for a change that cannot be skip-tolerated (unknown-tag skip, per the
///    shipped `w-skip` work) or append-tolerated — i.e. a breaking change an older build could not
///    parse or safely ignore. A change that older peers can skip past or that only appends new
///    trailing fields leaves ``minimum`` untouched.
/// 3. Field evolution is append-only: add new fields AFTER the last existing field, never insert
///    between or reorder existing fields. This is what keeps most changes append-tolerated and thus
///    ``minimum``-safe under rule 2.
public enum ProtocolVersion {
    /// Version this build speaks. Bump for ANY wire change (see the type's bump rules).
    public static let current: UInt16 = 1
    /// Oldest version this build can still interoperate with. Bump ONLY for a change that cannot be
    /// skip- or append-tolerated (see the type's bump rules).
    public static let minimum: UInt16 = 1

    /// Wire version at which `ServerHello` gained its appended `sessionToken` field (QUIC lane
    /// splitting, `screenshare-w6n`). A `ServerHello` whose `protocolVersion` is below this omits
    /// the field entirely on the wire; decode leaves `sessionToken` `nil` in that case, so an old
    /// peer that stops decoding after `chosenCodec` is unaffected.
    public static let laneVersion: UInt16 = 2

    /// Returns the agreed version (the lower of the two), or `nil` if it falls below ``minimum``.
    public static func negotiate(local: UInt16, remote: UInt16) -> UInt16? {
        let agreed = Swift.min(local, remote)
        return agreed >= minimum ? agreed : nil
    }
}

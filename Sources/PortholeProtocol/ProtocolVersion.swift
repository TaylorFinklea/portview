/// Wire-protocol version negotiation.
public enum ProtocolVersion {
    /// Version this build speaks.
    public static let current: UInt16 = 1
    /// Oldest version this build can still interoperate with.
    public static let minimum: UInt16 = 1

    /// Returns the agreed version (the lower of the two), or `nil` if it falls below ``minimum``.
    public static func negotiate(local: UInt16, remote: UInt16) -> UInt16? {
        let agreed = Swift.min(local, remote)
        return agreed >= minimum ? agreed : nil
    }
}

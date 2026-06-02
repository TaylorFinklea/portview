/// Errors raised while decoding the wire format.
public enum WireError: Error, Equatable, Sendable {
    /// Not enough bytes remain to decode the requested value.
    case truncated
    /// Bytes are present but structurally invalid (bad UTF-8, oversized varint, bad bool, …).
    case malformed(String)
    /// A frame referenced a message type byte we do not know.
    case unknownMessageType(UInt8)
    /// An enum field held a raw value outside its known cases.
    case unknownEnum(String, UInt64)
}

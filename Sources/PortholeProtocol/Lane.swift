/// Logical lanes carried over the single QUIC connection. Raw values are the wire encoding.
public enum Lane: UInt8, Sendable, CaseIterable {
    case control = 0
    case input = 1
    case video = 2
    case audio = 3
    case clipboard = 4
    case files = 5
}

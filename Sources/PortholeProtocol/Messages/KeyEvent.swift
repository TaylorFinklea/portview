/// Non-text keys that `TypeText` can't express. Raw values are the wire encoding.
public enum SpecialKey: UInt8, Sendable, CaseIterable {
    case returnKey = 0
    case delete = 1   // backspace
    case tab = 2
    case escape = 3
    case arrowLeft = 4
    case arrowRight = 5
    case arrowUp = 6
    case arrowDown = 7
}

/// Client → host. A single special-key tap (the host posts key-down then key-up).
public struct KeyEvent: WireMessage {
    public static let messageType = MessageType.keyEvent
    public var key: SpecialKey

    public init(key: SpecialKey) { self.key = key }

    public func encode(into w: inout BinaryWriter) {
        w.putUInt8(key.rawValue)
    }

    public init(from r: inout BinaryReader) throws {
        let raw = try r.uint8()
        guard let key = SpecialKey(rawValue: raw) else {
            throw WireError.unknownEnum("SpecialKey", UInt64(raw))
        }
        self.key = key
    }
}

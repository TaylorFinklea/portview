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

/// Client → host. A single key chord (the host posts key-down then key-up with the
/// given modifier flags). The key is either a `SpecialKey` or a single character —
/// the latter lets us send shortcuts like ⌘C without going through unicode typing.
public struct KeyEvent: WireMessage, Equatable {
    public static let messageType = MessageType.keyEvent

    public enum Key: Sendable, Equatable {
        case special(SpecialKey)
        case character(String)
    }

    public var key: Key
    public var modifiers: KeyModifiers

    public init(special: SpecialKey, modifiers: KeyModifiers = []) {
        self.key = .special(special)
        self.modifiers = modifiers
    }

    public init(character: String, modifiers: KeyModifiers = []) {
        self.key = .character(character)
        self.modifiers = modifiers
    }

    public func encode(into w: inout BinaryWriter) {
        w.putUInt8(modifiers.rawValue)
        switch key {
        case .special(let s):
            w.putUInt8(0)
            w.putUInt8(s.rawValue)
        case .character(let c):
            w.putUInt8(1)
            w.putString(c)
        }
    }

    public init(from r: inout BinaryReader) throws {
        modifiers = KeyModifiers(rawValue: try r.uint8())
        let kind = try r.uint8()
        switch kind {
        case 0:
            let raw = try r.uint8()
            guard let s = SpecialKey(rawValue: raw) else {
                throw WireError.unknownEnum("SpecialKey", UInt64(raw))
            }
            key = .special(s)
        case 1:
            key = .character(try r.string())
        default:
            throw WireError.unknownEnum("KeyEvent.Key", UInt64(kind))
        }
    }
}

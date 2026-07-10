// SPDX-License-Identifier: Apache-2.0
/// Which pointer button an event refers to. Raw values are the wire encoding.
public enum PointerButtonKind: UInt8, Sendable, CaseIterable {
    case left = 0
    case right = 1
    case other = 2
}

/// Client → host. A pointer button press or release.
public struct PointerButton: WireMessage {
    public static let messageType = MessageType.pointerButton
    public var button: PointerButtonKind
    public var isDown: Bool

    public init(button: PointerButtonKind, isDown: Bool) {
        self.button = button
        self.isDown = isDown
    }

    public func encode(into w: inout BinaryWriter) {
        w.putUInt8(button.rawValue)
        w.putBool(isDown)
    }

    public init(from r: inout BinaryReader) throws {
        let raw = try r.uint8()
        guard let kind = PointerButtonKind(rawValue: raw) else {
            throw WireError.unknownEnum("PointerButtonKind", UInt64(raw))
        }
        button = kind
        isDown = try r.bool()
    }
}

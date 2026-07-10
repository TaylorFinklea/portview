// SPDX-License-Identifier: Apache-2.0
/// Client → host. Relative pointer movement (trackpad-style); the host applies the delta
/// to the current cursor position and clamps to the display.
public struct PointerMove: WireMessage {
    public static let messageType = MessageType.pointerMove
    public var dx: Int32
    public var dy: Int32

    public init(dx: Int32, dy: Int32) {
        self.dx = dx
        self.dy = dy
    }

    public func encode(into w: inout BinaryWriter) {
        w.putUInt32(UInt32(bitPattern: dx))
        w.putUInt32(UInt32(bitPattern: dy))
    }

    public init(from r: inout BinaryReader) throws {
        dx = Int32(bitPattern: try r.uint32())
        dy = Int32(bitPattern: try r.uint32())
    }
}

/// Client → host. Scroll wheel delta (two-finger scroll).
public struct Scroll: WireMessage {
    public static let messageType = MessageType.scroll
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

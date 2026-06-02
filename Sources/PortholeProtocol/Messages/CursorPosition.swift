/// Host → client. The current cursor position, normalized to the display as 0…65535
/// (= 0.0…1.0) on each axis. Lets the client keep a zoomed viewport centered on the cursor
/// without coupling to pixel/point coordinate spaces.
public struct CursorPosition: WireMessage {
    public static let messageType = MessageType.cursorPosition
    public var nx: UInt16
    public var ny: UInt16

    public init(nx: UInt16, ny: UInt16) {
        self.nx = nx
        self.ny = ny
    }

    public init(normalizedX: Double, normalizedY: Double) {
        nx = UInt16((Swift.max(0, Swift.min(1, normalizedX)) * 65535).rounded())
        ny = UInt16((Swift.max(0, Swift.min(1, normalizedY)) * 65535).rounded())
    }

    public var normalizedX: Double { Double(nx) / 65535.0 }
    public var normalizedY: Double { Double(ny) / 65535.0 }

    public func encode(into w: inout BinaryWriter) {
        w.putUInt16(nx)
        w.putUInt16(ny)
    }

    public init(from r: inout BinaryReader) throws {
        nx = try r.uint16()
        ny = try r.uint16()
    }
}

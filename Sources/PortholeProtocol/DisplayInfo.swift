/// One display the host can offer to stream. `scaleX100` is points-per-pixel × 100 (e.g. 200 = 2.0×).
public struct DisplayInfo: Equatable, Sendable {
    public var id: UInt32
    public var name: String
    public var width: UInt32
    public var height: UInt32
    public var scaleX100: UInt16

    public init(id: UInt32, name: String, width: UInt32, height: UInt32, scaleX100: UInt16) {
        self.id = id; self.name = name; self.width = width; self.height = height; self.scaleX100 = scaleX100
    }

    func encode(into w: inout BinaryWriter) {
        w.putUInt32(id)
        w.putString(name)
        w.putUInt32(width)
        w.putUInt32(height)
        w.putUInt16(scaleX100)
    }

    init(from r: inout BinaryReader) throws {
        id = try r.uint32()
        name = try r.string()
        width = try r.uint32()
        height = try r.uint32()
        scaleX100 = try r.uint16()
    }
}

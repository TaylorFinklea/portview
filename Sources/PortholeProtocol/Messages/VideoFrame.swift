/// Host → client (video lane). One encoded access unit plus its metadata.
public struct VideoFrame: WireMessage {
    public static let messageType = MessageType.videoFrame
    public var sequence: UInt64
    public var ptsMicros: UInt64
    public var isKeyframe: Bool
    public var displayID: UInt32
    public var width: UInt32
    public var height: UInt32
    public var data: [UInt8]

    public init(sequence: UInt64, ptsMicros: UInt64, isKeyframe: Bool, displayID: UInt32, width: UInt32, height: UInt32, data: [UInt8]) {
        self.sequence = sequence; self.ptsMicros = ptsMicros; self.isKeyframe = isKeyframe
        self.displayID = displayID; self.width = width; self.height = height; self.data = data
    }

    public func encode(into w: inout BinaryWriter) {
        w.putUInt64(sequence)
        w.putUInt64(ptsMicros)
        w.putBool(isKeyframe)
        w.putUInt32(displayID)
        w.putUInt32(width)
        w.putUInt32(height)
        w.putData(data)
    }

    public init(from r: inout BinaryReader) throws {
        sequence = try r.uint64()
        ptsMicros = try r.uint64()
        isKeyframe = try r.bool()
        displayID = try r.uint32()
        width = try r.uint32()
        height = try r.uint32()
        data = try r.data()
    }
}

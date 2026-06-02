/// Client → host. Chosen display + desired stream parameters; host starts the video lane.
public struct StartSession: WireMessage {
    public static let messageType = MessageType.startSession
    public var displayID: UInt32
    public var codec: Codec
    public var maxWidth: UInt32
    public var maxHeight: UInt32
    public var maxFPS: UInt16
    public var targetBitrate: UInt32

    public init(displayID: UInt32, codec: Codec, maxWidth: UInt32, maxHeight: UInt32, maxFPS: UInt16, targetBitrate: UInt32) {
        self.displayID = displayID; self.codec = codec
        self.maxWidth = maxWidth; self.maxHeight = maxHeight
        self.maxFPS = maxFPS; self.targetBitrate = targetBitrate
    }

    public func encode(into w: inout BinaryWriter) {
        w.putUInt32(displayID)
        w.putUInt8(codec.rawValue)
        w.putUInt32(maxWidth)
        w.putUInt32(maxHeight)
        w.putUInt16(maxFPS)
        w.putUInt32(targetBitrate)
    }

    public init(from r: inout BinaryReader) throws {
        displayID = try r.uint32()
        let raw = try r.uint8()
        guard let c = Codec(rawValue: raw) else { throw WireError.unknownEnum("Codec", UInt64(raw)) }
        codec = c
        maxWidth = try r.uint32()
        maxHeight = try r.uint32()
        maxFPS = try r.uint16()
        targetBitrate = try r.uint32()
    }
}

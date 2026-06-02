/// Client → host. One ordered slice of a file announced by `FileOffer`. `isLast` marks the
/// final chunk (an empty last chunk terminates a zero-byte file).
public struct FileChunk: WireMessage, Equatable {
    public static let messageType = MessageType.fileChunk
    public var transferID: UInt32
    public var isLast: Bool
    public var data: [UInt8]

    public init(transferID: UInt32, isLast: Bool, data: [UInt8]) {
        self.transferID = transferID; self.isLast = isLast; self.data = data
    }

    public func encode(into w: inout BinaryWriter) {
        w.putUInt32(transferID)
        w.putBool(isLast)
        w.putData(data)
    }

    public init(from r: inout BinaryReader) throws {
        transferID = try r.uint32()
        isLast = try r.bool()
        data = try r.data()
    }
}

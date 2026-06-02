/// Client → host. Announces an incoming file push; followed by `FileChunk`s sharing the
/// same `transferID`. Chunking lets a large file interleave with live video on one connection.
public struct FileOffer: WireMessage, Equatable {
    public static let messageType = MessageType.fileOffer
    public var transferID: UInt32
    public var name: String
    public var size: UInt64

    public init(transferID: UInt32, name: String, size: UInt64) {
        self.transferID = transferID; self.name = name; self.size = size
    }

    public func encode(into w: inout BinaryWriter) {
        w.putUInt32(transferID)
        w.putString(name)
        w.putUInt64(size)
    }

    public init(from r: inout BinaryReader) throws {
        transferID = try r.uint32()
        name = try r.string()
        size = try r.uint64()
    }
}

/// Client → host. Asks the host to emit a keyframe immediately so the client's delta chain can
/// recover after a gap (returning from the background, or a decoder reset). No payload — the host
/// forces a keyframe on the connection's active capture.
public struct RequestKeyframe: WireMessage, Equatable, Sendable {
    public static let messageType = MessageType.requestKeyframe

    public init() {}
    public func encode(into w: inout BinaryWriter) {}
    public init(from r: inout BinaryReader) throws {}
}

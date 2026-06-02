/// A message with a stable type tag and an explicit binary encoding.
public protocol WireMessage: Equatable, Sendable {
    static var messageType: MessageType { get }
    func encode(into writer: inout BinaryWriter)
    init(from reader: inout BinaryReader) throws
}

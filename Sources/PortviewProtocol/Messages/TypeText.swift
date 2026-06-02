/// Client → host. Unicode text to type (drives the on-screen keyboard); the host injects
/// it as synthesized keyboard input.
public struct TypeText: WireMessage {
    public static let messageType = MessageType.typeText
    public var text: String

    public init(text: String) {
        self.text = text
    }

    public func encode(into w: inout BinaryWriter) {
        w.putString(text)
    }

    public init(from r: inout BinaryReader) throws {
        text = try r.string()
    }
}

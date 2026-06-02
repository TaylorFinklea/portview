/// The 1-byte tag identifying a message inside a frame. Raw values are the wire encoding.
public enum MessageType: UInt8, Sendable {
    case clientHello = 1
    case serverHello = 2
    case startSession = 3
    case videoFrame = 4
    case bye = 5
    case error = 6
}

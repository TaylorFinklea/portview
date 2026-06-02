/// Errors from the handshake state machines.
public enum HandshakeError: Error, Equatable, Sendable {
    case unexpectedMessage
    case versionMismatch
    case noCommonCodec
}

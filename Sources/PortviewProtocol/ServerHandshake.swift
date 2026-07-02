/// Drives the host side of the control-lane handshake. I/O-free.
public struct ServerHandshake {
    public enum State: Equatable, Sendable {
        case idle, awaitingStartSession, streaming, closed
    }
    public private(set) var state: State = .idle

    /// The wire version agreed with the client (the lower of the two speakers), set once the
    /// `ClientHello` is accepted; `nil` until then. Callers branch on this to gate versioned behavior.
    public private(set) var negotiatedVersion: UInt16?

    public let displays: [DisplayInfo]
    public let supportedCodecs: [Codec]

    public init(displays: [DisplayInfo], supportedCodecs: [Codec]) {
        self.displays = displays; self.supportedCodecs = supportedCodecs
    }

    /// Validate the `ClientHello`, pick a codec, and produce the `ServerHello`.
    public mutating func handle(_ hello: ClientHello) throws -> ServerHello {
        guard state == .idle else { throw HandshakeError.unexpectedMessage }
        guard let agreed = ProtocolVersion.negotiate(local: ProtocolVersion.current, remote: hello.protocolVersion) else {
            throw HandshakeError.versionMismatch
        }
        guard let codec = supportedCodecs.first(where: { hello.codecs.contains($0) }) else {
            throw HandshakeError.noCommonCodec
        }
        negotiatedVersion = agreed
        state = .awaitingStartSession
        return ServerHello(protocolVersion: ProtocolVersion.current, displays: displays, chosenCodec: codec)
    }

    /// Accept the client's `StartSession` and move to streaming.
    public mutating func handle(_ start: StartSession) throws {
        guard state == .awaitingStartSession else { throw HandshakeError.unexpectedMessage }
        state = .streaming
    }
}

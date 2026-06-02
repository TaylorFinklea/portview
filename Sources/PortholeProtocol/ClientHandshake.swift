/// Drives the client side of the control-lane handshake. I/O-free.
public struct ClientHandshake {
    public enum State: Equatable, Sendable {
        case idle, awaitingServerHello, ready, streaming, closed
    }
    public private(set) var state: State = .idle

    public let deviceID: String
    public let deviceName: String
    public let supportedCodecs: [Codec]

    public init(deviceID: String, deviceName: String, supportedCodecs: [Codec]) {
        self.deviceID = deviceID; self.deviceName = deviceName; self.supportedCodecs = supportedCodecs
    }

    /// Produce the opening `ClientHello`.
    public mutating func start() -> ClientHello {
        state = .awaitingServerHello
        return ClientHello(protocolVersion: ProtocolVersion.current,
                           deviceID: deviceID, deviceName: deviceName, codecs: supportedCodecs)
    }

    /// Validate the `ServerHello` and produce the `StartSession` to send.
    public mutating func handle(_ hello: ServerHello, displayID: UInt32, maxWidth: UInt32, maxHeight: UInt32, maxFPS: UInt16, targetBitrate: UInt32) throws -> StartSession {
        guard state == .awaitingServerHello else { throw HandshakeError.unexpectedMessage }
        guard ProtocolVersion.negotiate(local: ProtocolVersion.current, remote: hello.protocolVersion) != nil else {
            throw HandshakeError.versionMismatch
        }
        guard supportedCodecs.contains(hello.chosenCodec) else { throw HandshakeError.noCommonCodec }
        state = .ready
        return StartSession(displayID: displayID, codec: hello.chosenCodec,
                            maxWidth: maxWidth, maxHeight: maxHeight, maxFPS: maxFPS, targetBitrate: targetBitrate)
    }

    /// Call once the host's first video frame is flowing.
    public mutating func didStartStreaming() {
        if state == .ready { state = .streaming }
    }
}

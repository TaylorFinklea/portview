// SPDX-License-Identifier: Apache-2.0
/// Drives the host side of the control-lane handshake. I/O-free.
public struct ServerHandshake {
    public enum State: Equatable, Sendable {
        case idle, awaitingStartSession, streaming, closed
    }
    public private(set) var state: State = .idle

    /// The wire version agreed with the client (the lower of the two speakers), set once the
    /// `ClientHello` is accepted; `nil` until then. Callers branch on this to gate versioned behavior.
    public private(set) var negotiatedVersion: UInt16?

    /// The lane session token minted for this session — set iff the agreed version carries lanes
    /// (`>= ProtocolVersion.laneVersion`); the same token rides the `ServerHello`. An old-client
    /// session never mints one, so nothing lane-shaped is ever advertised to it.
    public private(set) var sessionToken: [UInt8]?

    public let displays: [DisplayInfo]
    public let supportedCodecs: [Codec]
    /// Version this host speaks. Injectable so tests can drive lane-version negotiation before
    /// `ProtocolVersion.current` itself moves to `laneVersion`.
    let localVersion: UInt16
    /// Mints the lane session token when the agreed version reaches `laneVersion`. Injected (the
    /// host passes `LaneSessionToken.mint`) because the CSPRNG lives above this I/O-free module;
    /// called at most once, and ONLY for a lane-capable session.
    let mintSessionToken: (@Sendable () -> [UInt8])?

    public init(displays: [DisplayInfo], supportedCodecs: [Codec],
                localVersion: UInt16 = ProtocolVersion.current,
                mintSessionToken: (@Sendable () -> [UInt8])? = nil) {
        self.displays = displays; self.supportedCodecs = supportedCodecs
        self.localVersion = localVersion; self.mintSessionToken = mintSessionToken
    }

    /// Validate the `ClientHello`, pick a codec, and produce the `ServerHello` — stamped with the
    /// NEGOTIATED version, not this host's own. The `ServerHello` codec puts the session token on
    /// the wire iff the STAMPED version is `>= laneVersion`, so stamping the agreed version is
    /// what keeps an old client's hello token-free (byte-identical to a pre-lane host) while a
    /// lane-capable pair gets the token minted and appended.
    public mutating func handle(_ hello: ClientHello) throws -> ServerHello {
        guard state == .idle else { throw HandshakeError.unexpectedMessage }
        guard let agreed = ProtocolVersion.negotiate(local: localVersion, remote: hello.protocolVersion) else {
            throw HandshakeError.versionMismatch
        }
        guard let codec = supportedCodecs.first(where: { hello.codecs.contains($0) }) else {
            throw HandshakeError.noCommonCodec
        }
        negotiatedVersion = agreed
        state = .awaitingStartSession
        if agreed >= ProtocolVersion.laneVersion {
            // Never remote-reachable while the host wires a minter (HostRunner always does): the
            // agreed version can only reach laneVersion if localVersion did, a local configuration.
            guard let mintSessionToken else {
                preconditionFailure("lane-version handshake requires a session-token minter")
            }
            sessionToken = mintSessionToken()
        }
        return ServerHello(protocolVersion: agreed, displays: displays, chosenCodec: codec,
                           sessionToken: sessionToken)
    }

    /// Accept the client's `StartSession` and move to streaming.
    public mutating func handle(_ start: StartSession) throws {
        guard state == .awaitingStartSession else { throw HandshakeError.unexpectedMessage }
        state = .streaming
    }
}

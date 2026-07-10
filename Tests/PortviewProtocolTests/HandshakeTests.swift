// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import PortviewProtocol

@Suite struct HandshakeTests {
    @Test func happyPathDrivesBothSidesToStreaming() throws {
        var client = ClientHandshake(deviceID: "D", deviceName: "Phone", supportedCodecs: [.hevc, .h264])
        var server = ServerHandshake(
            displays: [DisplayInfo(id: 1, name: "Built-in", width: 3456, height: 2234, scaleX100: 200)],
            supportedCodecs: [.hevc]
        )

        let hello = client.start()
        #expect(client.state == .awaitingServerHello)

        let serverHello = try server.handle(hello)
        #expect(server.state == .awaitingStartSession)
        #expect(serverHello.chosenCodec == .hevc)
        #expect(server.negotiatedVersion == ProtocolVersion.current)

        let start = try client.handle(serverHello, displayID: 1, maxWidth: 3456, maxHeight: 2234, maxFPS: 60, targetBitrate: 25_000_000)
        #expect(client.state == .ready)
        #expect(client.negotiatedVersion == ProtocolVersion.current)

        try server.handle(start)
        #expect(server.state == .streaming)

        client.didStartStreaming()
        #expect(client.state == .streaming)
    }

    @Test func serverRejectsHelloWithNoCommonCodec() {
        var server = ServerHandshake(displays: [], supportedCodecs: [.hevc])
        let hello = ClientHello(protocolVersion: 1, deviceID: "D", deviceName: "P", codecs: [.h264])
        #expect(throws: HandshakeError.noCommonCodec) {
            _ = try server.handle(hello)
        }
    }

    @Test func clientRejectsServerHelloBeforeStarting() {
        var client = ClientHandshake(deviceID: "D", deviceName: "P", supportedCodecs: [.hevc])
        let serverHello = ServerHello(protocolVersion: 1, displays: [], chosenCodec: .hevc)
        #expect(throws: HandshakeError.unexpectedMessage) {
            _ = try client.handle(serverHello, displayID: 0, maxWidth: 0, maxHeight: 0, maxFPS: 0, targetBitrate: 0)
        }
    }

    @Test func serverRejectsVersionBelowMinimum() {
        var server = ServerHandshake(displays: [], supportedCodecs: [.hevc])
        let hello = ClientHello(protocolVersion: 0, deviceID: "D", deviceName: "P", codecs: [.hevc])
        #expect(throws: HandshakeError.versionMismatch) {
            _ = try server.handle(hello)
        }
    }

    /// Pure negotiation across (local, remote) pairs: agree on the lower of the two, or reject below minimum (1).
    @Test(arguments: [
        // (local, remote, expected) — nil ⇒ below minimum, no agreement.
        (UInt16(1), UInt16(1), UInt16?.some(1)),   // same version
        (UInt16(1), UInt16(2), UInt16?.some(1)),   // remote ahead → agree on local
        (UInt16(3), UInt16(2), UInt16?.some(2)),   // local ahead → agree on remote
        (UInt16(1), UInt16(0), UInt16?.none),      // remote below minimum → reject
        (UInt16(0), UInt16(1), UInt16?.none),      // local below minimum → reject
    ])
    func negotiateAgreesOnLowerOrRejectsBelowMinimum(local: UInt16, remote: UInt16, expected: UInt16?) {
        #expect(ProtocolVersion.negotiate(local: local, remote: remote) == expected)
    }

    /// The server handshake stores the agreed wire version (or nil on a below-minimum reject).
    @Test(arguments: [
        // (remote, expectedAgreed) — local is ProtocolVersion.current (1); nil ⇒ reject below minimum (1).
        (UInt16(0), UInt16?.none),         // below minimum → versionMismatch
        (UInt16(1), UInt16?.some(1)),      // same version → agree on 1
        (UInt16(2), UInt16?.some(1)),      // client ahead → cross-version accept, agree on local (1)
    ])
    func serverExposesNegotiatedVersion(remote: UInt16, expectedAgreed: UInt16?) throws {
        var server = ServerHandshake(displays: [], supportedCodecs: [.hevc])
        let hello = ClientHello(protocolVersion: remote, deviceID: "D", deviceName: "P", codecs: [.hevc])
        if let expectedAgreed {
            let serverHello = try server.handle(hello)
            #expect(server.negotiatedVersion == expectedAgreed)
            // The ServerHello is stamped with the NEGOTIATED version (not the host's own): the
            // stamp is what version-gates the appended lane session token on the wire.
            #expect(serverHello.protocolVersion == expectedAgreed)
        } else {
            #expect(throws: HandshakeError.versionMismatch) { _ = try server.handle(hello) }
            #expect(server.negotiatedVersion == nil)
        }
    }

    /// QUIC lane-splitting (w6n.4): a lane-capable pair (agreed version >= laneVersion) mints the
    /// session token and both attaches it to the ServerHello and exposes it to the host wiring
    /// (which authorizes lane streams with the SAME token).
    @Test func laneCapableHandshakeMintsAndAttachesSessionToken() throws {
        let token = Array(repeating: UInt8(0xC3), count: 32)
        var server = ServerHandshake(displays: [], supportedCodecs: [.hevc],
                                     localVersion: ProtocolVersion.laneVersion,
                                     mintSessionToken: { token })
        let hello = ClientHello(protocolVersion: ProtocolVersion.laneVersion,
                                deviceID: "D", deviceName: "P", codecs: [.hevc])

        let serverHello = try server.handle(hello)

        #expect(server.negotiatedVersion == ProtocolVersion.laneVersion)
        #expect(serverHello.protocolVersion == ProtocolVersion.laneVersion)
        #expect(serverHello.sessionToken == token)
        #expect(server.sessionToken == token)
    }

    /// Old-version passthrough (w6n.4): when a lane-capable HOST meets a pre-lane client, the
    /// ServerHello is stamped with the negotiated (pre-lane) version and carries NO token — and
    /// the host must not even MINT one for that session.
    @Test func oldClientHandshakeStampsNegotiatedVersionWithoutMintingAToken() throws {
        var server = ServerHandshake(displays: [], supportedCodecs: [.hevc],
                                     localVersion: ProtocolVersion.laneVersion,
                                     mintSessionToken: {
                                         Issue.record("minted a lane session token for a pre-lane client")
                                         return []
                                     })
        let hello = ClientHello(protocolVersion: 1, deviceID: "D", deviceName: "P", codecs: [.hevc])

        let serverHello = try server.handle(hello)

        #expect(server.negotiatedVersion == 1)
        #expect(serverHello.protocolVersion == 1)
        #expect(serverHello.sessionToken == nil)
        #expect(server.sessionToken == nil)
    }

    /// The client handshake stores the agreed wire version (or nil on a below-minimum reject).
    @Test(arguments: [
        (UInt16(0), UInt16?.none),         // below minimum → versionMismatch
        (UInt16(1), UInt16?.some(1)),      // same version → agree on 1
        (UInt16(2), UInt16?.some(1)),      // host ahead → cross-version accept, agree on local (1)
    ])
    func clientExposesNegotiatedVersion(remote: UInt16, expectedAgreed: UInt16?) throws {
        var client = ClientHandshake(deviceID: "D", deviceName: "P", supportedCodecs: [.hevc])
        _ = client.start()
        let serverHello = ServerHello(protocolVersion: remote, displays: [], chosenCodec: .hevc)
        if let expectedAgreed {
            _ = try client.handle(serverHello, displayID: 0, maxWidth: 0, maxHeight: 0, maxFPS: 0, targetBitrate: 0)
            #expect(client.negotiatedVersion == expectedAgreed)
        } else {
            #expect(throws: HandshakeError.versionMismatch) {
                _ = try client.handle(serverHello, displayID: 0, maxWidth: 0, maxHeight: 0, maxFPS: 0, targetBitrate: 0)
            }
            #expect(client.negotiatedVersion == nil)
        }
    }
}

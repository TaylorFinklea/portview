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
            #expect(serverHello.protocolVersion == ProtocolVersion.current)
        } else {
            #expect(throws: HandshakeError.versionMismatch) { _ = try server.handle(hello) }
            #expect(server.negotiatedVersion == nil)
        }
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

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

        let start = try client.handle(serverHello, displayID: 1, maxWidth: 3456, maxHeight: 2234, maxFPS: 60, targetBitrate: 25_000_000)
        #expect(client.state == .ready)

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
}

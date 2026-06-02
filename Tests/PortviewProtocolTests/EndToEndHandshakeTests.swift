import Testing
@testable import PortviewProtocol

@Suite struct EndToEndHandshakeTests {
    /// Serialize a message to a frame, push it through a decoder, and return the single decoded message.
    private func ship<M: WireMessage>(_ message: M, into decoder: inout FrameDecoder) throws -> AnyMessage {
        let out = try decoder.push(Frame.encode(message))
        #expect(out.count == 1)
        return out[0]
    }

    @Test func fullHandshakeSurvivesFrameRoundTrips() throws {
        var client = ClientHandshake(deviceID: "PHONE-1", deviceName: "iPhone", supportedCodecs: [.hevc, .h264])
        var server = ServerHandshake(
            displays: [DisplayInfo(id: 1, name: "Built-in", width: 3456, height: 2234, scaleX100: 200)],
            supportedCodecs: [.hevc]
        )
        var toServer = FrameDecoder()
        var toClient = FrameDecoder()

        // client → server: ClientHello
        guard case let .clientHello(hello) = try ship(client.start(), into: &toServer) else {
            Issue.record("expected ClientHello"); return
        }
        // server → client: ServerHello
        guard case let .serverHello(serverHello) = try ship(try server.handle(hello), into: &toClient) else {
            Issue.record("expected ServerHello"); return
        }
        // client → server: StartSession
        let start = try client.handle(serverHello, displayID: 1, maxWidth: 3456, maxHeight: 2234, maxFPS: 60, targetBitrate: 25_000_000)
        guard case let .startSession(decodedStart) = try ship(start, into: &toServer) else {
            Issue.record("expected StartSession"); return
        }
        try server.handle(decodedStart)
        client.didStartStreaming()

        #expect(server.state == .streaming)
        #expect(client.state == .streaming)
        #expect(serverHello.chosenCodec == .hevc)
        #expect(decodedStart.displayID == 1)
    }
}

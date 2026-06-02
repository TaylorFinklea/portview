import Testing
@testable import PortholeProtocol

/// Encode a message to bytes, decode it back, and assert equality.
private func roundTrip<M: WireMessage>(_ message: M) throws -> M {
    var w = BinaryWriter()
    message.encode(into: &w)
    var r = BinaryReader(w.bytes)
    return try M(from: &r)
}

@Suite struct HelloMessageTests {
    @Test func clientHelloRoundTrips() throws {
        let m = ClientHello(
            protocolVersion: 1,
            deviceID: "DEVICE-123",
            deviceName: "Taylor's iPhone",
            codecs: [.hevc, .h264]
        )
        #expect(try roundTrip(m) == m)
        #expect(ClientHello.messageType == .clientHello)
    }

    @Test func serverHelloRoundTrips() throws {
        let m = ServerHello(
            protocolVersion: 1,
            displays: [
                DisplayInfo(id: 1, name: "Built-in", width: 3456, height: 2234, scaleX100: 200),
                DisplayInfo(id: 2, name: "Studio Display", width: 5120, height: 2880, scaleX100: 200),
            ],
            chosenCodec: .hevc
        )
        #expect(try roundTrip(m) == m)
        #expect(ServerHello.messageType == .serverHello)
    }

    @Test func unknownCodecByteThrows() {
        // protocolVersion=1, deviceID="", deviceName="", codecs count=1, codec raw=99
        let bytes: [UInt8] = [0x00, 0x01, 0x00, 0x00, 0x01, 99]
        var r = BinaryReader(bytes)
        #expect(throws: WireError.unknownEnum("Codec", 99)) {
            _ = try ClientHello(from: &r)
        }
    }
}

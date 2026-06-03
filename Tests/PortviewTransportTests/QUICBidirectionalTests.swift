import Testing
import Foundation
import Network
@testable import PortviewTransport
@testable import PortviewProtocol

@Suite struct QUICBidirectionalTests {
    /// Full bidirectional round-trip over QUIC through the REAL transport types:
    /// client `connectQUIC` → ClientHello → server (serving each accepted connection
    /// concurrently, tolerating QUIC's double-delivery) → ServerHello → client receives it.
    /// This is the path the prior session deferred; the empirical sweep showed a bare QUIC
    /// `NWConnection` is one bidirectional stream and the round-trip works (no multiplex group).
    @Test func quicBidirectionalRoundTrip() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let pin = try identity.certificateSHA256()

        let listener = try PortviewListener(quicIdentity: identity)
        let port = try await withTimeout(.seconds(15)) { try await listener.start() }

        // Serve each accepted connection concurrently — QUIC delivers a dead "control" connection
        // plus the real one; reply with a ServerHello on whichever carries the ClientHello.
        let serverTask = Task {
            for await connection in listener.connections {
                Task {
                    for await message in connection.inbound {
                        if case .clientHello = message {
                            try? await connection.send(.serverHello(ServerHello(
                                protocolVersion: 1, displays: [], chosenCodec: .hevc)))
                        }
                    }
                }
            }
        }

        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let client = try await withTimeout(.seconds(15)) {
            try await PortviewConnection.connectQUIC(to: endpoint, pinnedCertificateSHA256: pin)
        }
        try await client.send(.clientHello(ClientHello(
            protocolVersion: 1, deviceID: "QUIC", deviceName: "Bidi", codecs: [.hevc])))

        let reply = try await withTimeout(.seconds(15)) {
            for await message in client.inbound { return message }
            throw TimeoutError()
        }

        serverTask.cancel()
        client.close()
        listener.cancel()

        guard case .serverHello(let hello) = reply else {
            Issue.record("expected ServerHello over QUIC, got \(reply)")
            return
        }
        #expect(hello.chosenCodec == .hevc)
    }
}

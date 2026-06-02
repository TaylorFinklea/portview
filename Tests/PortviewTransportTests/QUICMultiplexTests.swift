import Testing
import Foundation
import Network
@testable import PortviewTransport
@testable import PortviewProtocol

@Suite struct QUICMultiplexTests {
    /// Proves the QUIC multiplex-group model carries a full BIDIRECTIONAL exchange through
    /// `PortviewConnection`/`PortviewListener`: the client opens a QUIC stream and sends a
    /// `ClientHello`; the server receives it and replies with a `ServerHello` on the same stream;
    /// the client receives the reply. This is the path the bare-`NWConnection` QUIC client
    /// couldn't achieve (it double-delivered connections / hung on reply); see decisions.md.
    ///
    /// DISABLED: reproduces the documented NWConnectionGroup/NWMultiplexGroup chicken-and-egg —
    /// waiting for the group's `.ready` before opening a stream hangs (the group never readies
    /// on its own), and opening a stream immediately after `start()` returns nil (`streamUnavailable`,
    /// the group can't vend a stream yet). Enable once the correct client choreography is nailed
    /// down (candidate: open the stream on the group's queue post-start; needs device validation).
    /// TLS-over-TCP remains the shipping transport. See .docs/ai/decisions.md.
    @Test(.disabled("Reproduces the NWConnectionGroup QUIC chicken-and-egg; TLS-over-TCP ships. See decisions.md."))
    func quicMultiplexRoundTripsBothDirections() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let pin = try identity.certificateSHA256()

        let listener = try PortviewListener(quicIdentity: identity)
        let port = try await withTimeout(.seconds(15)) { try await listener.start() }

        // Server: accept the first stream and reply with a ServerHello when a ClientHello arrives.
        let serverTask = Task {
            for await connection in listener.connections {
                for await message in connection.inbound {
                    if case .clientHello = message {
                        try? await connection.send(.serverHello(ServerHello(
                            protocolVersion: 1, displays: [], chosenCodec: .hevc)))
                    }
                }
                break
            }
        }

        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let client = try await withTimeout(.seconds(15)) {
            try await PortviewConnection.connectQUIC(to: endpoint, pinnedCertificateSHA256: pin)
        }

        let hello = ClientHello(protocolVersion: 1, deviceID: "QUIC", deviceName: "Multiplex", codecs: [.hevc])
        try await client.send(.clientHello(hello))

        let reply = try await withTimeout(.seconds(15)) {
            for await message in client.inbound { return message }
            throw TimeoutError()
        }

        serverTask.cancel()
        client.close()
        listener.cancel()

        guard case .serverHello(let serverHello) = reply else {
            Issue.record("expected ServerHello over QUIC, got \(reply)")
            return
        }
        #expect(serverHello.chosenCodec == .hevc)
    }
}

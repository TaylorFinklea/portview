import Testing
import Foundation
import Network
@testable import PortviewTransport
@testable import PortviewProtocol

@Suite struct HandshakeOverConnectionTests {
    /// The full PortviewProtocol handshake driven over a real localhost TLS connection
    /// (certificate-pinned), followed by one VideoFrame delivered host -> client.
    /// Exercises PortviewConnection, PortviewListener, and certificate pinning together.
    @Test func handshakeAndFirstVideoFrame() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let pin = try identity.certificateSHA256()

        let listener = try PortviewListener(identity: identity)
        let port = try await listener.start()

        let videoData: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD]

        // --- HOST: accept one connection, drive the server handshake, send a VideoFrame ---
        let serverTask = Task { () -> ServerHandshake.State in
            var server = ServerHandshake(
                displays: [DisplayInfo(id: 1, name: "Built-in", width: 3456, height: 2234, scaleX100: 200)],
                supportedCodecs: [.hevc]
            )
            for await connection in listener.connections {
                for await message in connection.inbound {
                    switch message {
                    case .clientHello(let hello):
                        try await connection.send(.serverHello(server.handle(hello)))
                    case .startSession(let start):
                        try server.handle(start)
                        try await connection.send(.videoFrame(VideoFrame(
                            sequence: 1, ptsMicros: 0, isKeyframe: true,
                            displayID: 1, width: 2560, height: 1440, data: videoData
                        )))
                        return server.state
                    default:
                        break
                    }
                }
            }
            return server.state
        }

        // --- CLIENT: connect (pinned), run the client handshake, await the first frame ---
        let clientResult = try await withTimeout(.seconds(15)) { () -> (ClientHandshake.State, VideoFrame?) in
            let connection = try await PortviewConnection.connect(
                to: .hostPort(host: "127.0.0.1", port: port),
                pinnedCertificateSHA256: pin
            )
            var client = ClientHandshake(deviceID: "PHONE", deviceName: "iPhone", supportedCodecs: [.hevc, .h264])
            try await connection.send(.clientHello(client.start()))

            var received: VideoFrame?
            for await message in connection.inbound {
                switch message {
                case .serverHello(let hello):
                    let start = try client.handle(hello, displayID: 1, maxWidth: 2560, maxHeight: 1440, maxFPS: 60, targetBitrate: 25_000_000)
                    try await connection.send(.startSession(start))
                    client.didStartStreaming()
                case .videoFrame(let frame):
                    received = frame
                default:
                    break
                }
                if received != nil { break }
            }
            connection.close()
            return (client.state, received)
        }

        let serverState = try await withTimeout(.seconds(5)) { try await serverTask.value }
        listener.cancel()

        #expect(clientResult.0 == .streaming)
        #expect(serverState == .streaming)
        #expect(clientResult.1?.sequence == 1)
        #expect(clientResult.1?.data == videoData)
    }
}

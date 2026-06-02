import Testing
import Foundation
import Network
import CoreVideo
@testable import PortviewMedia
@testable import PortviewTransport
@testable import PortviewProtocol

@Suite struct PipelineE2ETests {
    /// THE core POC, end to end, autonomously: a frame is HEVC-encoded on the host,
    /// serialized, sent as a `VideoFrame` over a real certificate-pinned TLS connection,
    /// deserialized on the client, HEVC-decoded, and its colour verified. This exercises
    /// PortviewMedia + PortviewProtocol + PortviewTransport together — everything except
    /// real screen capture (needs Screen-Recording permission) and on-screen render.
    @Test func framePipesFromHostEncodeToClientDecode() async throws {
        let width = 320, height = 240
        let (inB, inG, inR): (UInt8, UInt8, UInt8) = (15, 200, 30) // a strong green

        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let pin = try identity.certificateSHA256()
        let listener = try PortviewListener(identity: identity)
        let port = try await listener.start()

        // --- HOST: encode a frame, serialize it, send it as a VideoFrame ---
        let hostTask = Task {
            for await connection in listener.connections {
                let frame = makeSolidBGRA(width: width, height: height, b: inB, g: inG, r: inR)
                let encoder = try VideoEncoder(width: width, height: height)
                let encoded = try await encoder.encode(frame, presentationTime: .zero)
                let sample = try VideoSampleSerializer.serialize(encoded)
                try await connection.send(.videoFrame(VideoFrame(
                    sequence: 1, ptsMicros: 0, isKeyframe: sample.isKeyframe,
                    displayID: 1, width: UInt32(width), height: UInt32(height),
                    data: sample.serialized()
                )))
                return
            }
        }

        // --- CLIENT: receive the VideoFrame, deserialize, decode, read the colour ---
        let color = try await withTimeout(.seconds(20)) { () -> (b: UInt8, g: UInt8, r: UInt8) in
            let connection = try await PortviewConnection.connect(
                to: .hostPort(host: "127.0.0.1", port: port),
                pinnedCertificateSHA256: pin
            )
            for await message in connection.inbound {
                guard case .videoFrame(let videoFrame) = message else { continue }
                let sample = try EncodedVideoSample(serialized: videoFrame.data)
                let rebuilt = try VideoSampleSerializer.deserialize(sample)
                let decoder = VideoDecoder()
                let output = try await decoder.decode(rebuilt)
                connection.close()
                return centerPixelBGRA(output)
            }
            throw TimeoutError()
        }

        _ = try await withTimeout(.seconds(5)) { try await hostTask.value }
        listener.cancel()

        #expect(abs(Int(color.r) - Int(inR)) < 35)
        #expect(abs(Int(color.g) - Int(inG)) < 35)
        #expect(abs(Int(color.b) - Int(inB)) < 35)
    }
}

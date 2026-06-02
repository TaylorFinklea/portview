import Foundation
import Network
import UIKit
import CoreMedia
import PortholeProtocol
import PortholeTransport
import PortholeMedia

/// Drives a Porthole client session: connect (cert-pinned) → handshake → receive video
/// frames → rebuild sample buffers → enqueue for display.
@MainActor
final class SessionViewModel: ObservableObject {
    enum Status: Equatable {
        case idle, connecting, streaming, failed(String)
    }

    @Published var status: Status = .idle
    let renderer = VideoRenderer()
    private var task: Task<Void, Never>?

    func connect(host: String, port: UInt16, pinHex: String) {
        guard let pin = Data(hexString: pinHex), pin.count == 32 else {
            status = .failed("Pin must be 64 hex characters.")
            return
        }
        status = .connecting
        task?.cancel()
        task = Task { [weak self] in await self?.run(host: host, port: port, pin: pin) }
    }

    func disconnect() {
        task?.cancel()
        task = nil
        status = .idle
    }

    private func run(host: String, port: UInt16, pin: Data) async {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            status = .failed("Invalid port.")
            return
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        do {
            let connection = try await PortholeConnection.connect(to: endpoint, pinnedCertificateSHA256: pin)
            var client = ClientHandshake(
                deviceID: UIDevice.current.identifierForVendor?.uuidString ?? "ios-client",
                deviceName: UIDevice.current.name,
                supportedCodecs: [.hevc]
            )
            try await connection.send(.clientHello(client.start()))

            for await message in connection.inbound {
                switch message {
                case .serverHello(let hello):
                    guard let display = hello.displays.first else { continue }
                    let start = try client.handle(
                        hello, displayID: display.id,
                        maxWidth: display.width, maxHeight: display.height,
                        maxFPS: 60, targetBitrate: 25_000_000
                    )
                    try await connection.send(.startSession(start))
                    client.didStartStreaming()
                    status = .streaming
                case .videoFrame(let frame):
                    if let sample = try? rebuild(frame) {
                        renderer.enqueue(sample)
                    }
                case .error(let error):
                    status = .failed("Host error: \(error.message)")
                    return
                default:
                    break
                }
            }
            if status == .streaming { status = .idle } // connection closed
        } catch {
            status = .failed("\(error)")
        }
    }

    private func rebuild(_ frame: VideoFrame) throws -> CMSampleBuffer {
        let encoded = try EncodedVideoSample(serialized: frame.data)
        return try VideoSampleSerializer.deserialize(encoded)
    }
}

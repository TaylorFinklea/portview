import Foundation
import Network
import UIKit
import CoreMedia
import PortviewProtocol
import PortviewTransport
import PortviewMedia

/// Drives a Portview client session: connect (cert-pinned) → handshake → receive video
/// frames → rebuild sample buffers → enqueue for display.
@MainActor
final class SessionViewModel: ObservableObject {
    enum Status: Equatable {
        case idle, connecting, streaming, failed(String)
    }

    @Published var status: Status = .idle
    /// Latest cursor position reported by the host, normalized to the display (0…1).
    @Published var cursorNormalized = CGPoint(x: 0.5, y: 0.5)
    let renderer = VideoRenderer()
    private var task: Task<Void, Never>?
    private var connection: PortviewConnection?
    /// Mac display size in points (from ServerHello); used to predict the cursor locally.
    private var displaySize = CGSize(width: 1, height: 1)
    /// Must match the host's InputInjector sensitivity so the predicted cursor tracks the real one.
    private let inputSensitivity: CGFloat = 1.5

    func connect(host: String, port: UInt16, pinHex: String) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            status = .failed("Invalid port.")
            return
        }
        start(endpoint: .hostPort(host: NWEndpoint.Host(host), port: nwPort), pinHex: pinHex)
    }

    /// Connect to a Bonjour-discovered host (user still supplies the pin).
    func connect(to host: DiscoveredHost, pinHex: String) {
        start(endpoint: host.endpoint, pinHex: pinHex)
    }

    /// Connect from a scanned QR pairing payload (host, port, and pin all included).
    func connect(payload: PairingPayload) {
        connect(host: payload.host, port: payload.port, pinHex: payload.pinHex)
    }

    private func start(endpoint: NWEndpoint, pinHex: String) {
        guard let pin = Data(hexString: pinHex), pin.count == 32 else {
            status = .failed("Pin must be 64 hex characters.")
            return
        }
        status = .connecting
        task?.cancel()
        task = Task { [weak self] in await self?.run(endpoint: endpoint, pin: pin) }
    }

    func disconnect() {
        connection?.close()
        connection = nil
        task?.cancel()
        task = nil
        status = .idle
    }

    // MARK: - Input (client → host)

    func sendPointerMove(dx: CGFloat, dy: CGFloat) {
        let sentDx = dx.rounded()
        let sentDy = dy.rounded()
        send(.pointerMove(PointerMove(dx: Int32(sentDx), dy: Int32(sentDy))))
        // Predict the cursor locally for instant zoom-follow, using the exact delta we sent so
        // the prediction stays in lockstep with the host (its CursorPosition then matches, no snap).
        let nx = min(1, max(0, cursorNormalized.x + sentDx * inputSensitivity / displaySize.width))
        let ny = min(1, max(0, cursorNormalized.y + sentDy * inputSensitivity / displaySize.height))
        cursorNormalized = CGPoint(x: nx, y: ny)
    }

    func sendClick() {
        send(.pointerButton(PointerButton(button: .left, isDown: true)))
        send(.pointerButton(PointerButton(button: .left, isDown: false)))
    }

    func sendScroll(dx: CGFloat, dy: CGFloat) {
        send(.scroll(Scroll(dx: Int32(dx.rounded()), dy: Int32(dy.rounded()))))
    }

    func sendText(_ text: String) {
        send(.typeText(TypeText(text: text)))
    }

    func sendKey(_ key: SpecialKey) {
        send(.keyEvent(KeyEvent(key: key)))
    }

    private func send(_ message: AnyMessage) {
        guard let connection else { return }
        Task { try? await connection.send(message) }
    }

    private func run(endpoint: NWEndpoint, pin: Data) async {
        do {
            let connection = try await PortviewConnection.connect(to: endpoint, pinnedCertificateSHA256: pin)
            self.connection = connection
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
                    displaySize = CGSize(width: max(1, Double(display.width)), height: max(1, Double(display.height)))
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
                case .cursorPosition(let cursor):
                    cursorNormalized = CGPoint(x: cursor.normalizedX, y: cursor.normalizedY)
                case .error(let error):
                    status = .failed("Host error: \(error.message)")
                    return
                default:
                    break
                }
            }
            if status == .streaming { status = .idle } // connection closed
            self.connection = nil
        } catch {
            status = .failed("\(error)")
            self.connection = nil
        }
    }

    private func rebuild(_ frame: VideoFrame) throws -> CMSampleBuffer {
        let encoded = try EncodedVideoSample(serialized: frame.data)
        return try VideoSampleSerializer.deserialize(encoded)
    }
}

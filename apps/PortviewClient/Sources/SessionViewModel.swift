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
    /// Displays the host offered (from ServerHello) and which one is currently streaming.
    @Published var displays: [DisplayInfo] = []
    @Published var activeDisplayID: UInt32 = 0
    /// Transient status of an in-flight file push (nil when none).
    @Published var transferStatus: String?
    /// Normalized region of the display the host's current frames represent (the magnifier crop).
    /// Updated when the host confirms a viewport; the client renders the residual zoom against it.
    @Published var frameViewport = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var pendingViewport = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var lastViewportSent = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var viewportSendScheduled = false
    let renderer = MetalVideoRenderer()
    private let decoder = VideoDecoder()
    private let audioPlayer = AudioPlayer()
    private var task: Task<Void, Never>?
    private var connection: PortviewConnection?
    /// Mac display size in points (from ServerHello); used to predict the cursor locally and to
    /// letterbox-correct the client's zoom/pan math.
    @Published private(set) var displaySize = CGSize(width: 1, height: 1)
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
        displays = []
        activeDisplayID = 0
        resetViewport()
        audioPlayer.stop()
    }

    /// Re-target the live stream to another of the host's displays (no reconnect).
    func switchDisplay(to displayID: UInt32) {
        guard displayID != activeDisplayID,
              let display = displays.first(where: { $0.id == displayID }) else { return }
        activeDisplayID = displayID
        displaySize = CGSize(width: max(1, Double(display.width)), height: max(1, Double(display.height)))
        cursorNormalized = CGPoint(x: 0.5, y: 0.5)
        resetViewport()
        send(.switchDisplay(SwitchDisplay(displayID: displayID)))
    }

    /// Ask the host to crop its capture to `rect` (normalized) — the magnifier. Coalesced to ~12 Hz
    /// (with a trailing send) so a fast pinch/pan doesn't thrash the host's stream reconfiguration.
    func requestViewport(_ rect: CGRect) {
        pendingViewport = rect
        guard !viewportSendScheduled else { return }
        viewportSendScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self else { return }
            self.viewportSendScheduled = false
            let rect = self.pendingViewport
            guard rect != self.lastViewportSent else { return }
            self.lastViewportSent = rect
            self.send(.viewport(Viewport(
                displayID: self.activeDisplayID,
                normalizedX: rect.minX, normalizedY: rect.minY,
                normalizedW: rect.width, normalizedH: rect.height)))
        }
    }

    private func resetViewport() {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        frameViewport = full
        pendingViewport = full
        lastViewportSent = full
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

    func sendKey(_ key: SpecialKey, modifiers: KeyModifiers = []) {
        send(.keyEvent(KeyEvent(special: key, modifiers: modifiers)))
    }

    /// Send a single character as a key chord (used for shortcuts like ⌘C).
    func sendChar(_ character: String, modifiers: KeyModifiers) {
        send(.keyEvent(KeyEvent(character: character, modifiers: modifiers)))
    }

    /// Push the iPhone's clipboard text to the Mac (user-initiated; iOS restricts auto-reads).
    func pasteToHost() {
        if let text = UIPasteboard.general.string, !text.isEmpty {
            send(.clipboardUpdate(ClipboardUpdate(text: text)))
        }
    }

    /// Push a file to the Mac (saved to its ~/Downloads). Announce it, then stream ordered
    /// 64 KB chunks within one Task so they stay in order and interleave with live video.
    func sendFile(name: String, data: Data) {
        guard let connection else { return }
        let transferID = UInt32.random(in: 1...UInt32.max)
        let bytes = [UInt8](data)
        transferStatus = "Sending \(name)…"
        Task { [weak self] in
            do {
                try await connection.send(.fileOffer(FileOffer(transferID: transferID, name: name, size: UInt64(bytes.count))))
                let chunkSize = 64 * 1024
                var offset = 0
                repeat {
                    let end = min(offset + chunkSize, bytes.count)
                    let isLast = end >= bytes.count
                    try await connection.send(.fileChunk(FileChunk(transferID: transferID, isLast: isLast, data: Array(bytes[offset..<end]))))
                    offset = end
                } while offset < bytes.count
                self?.transferStatus = "Sent \(name)"
            } catch {
                self?.transferStatus = "Send failed: \(name)"
            }
        }
    }

    private func send(_ message: AnyMessage) {
        guard let connection else { return }
        Task { try? await connection.send(message) }
    }

    private func run(endpoint: NWEndpoint, pin: Data) async {
        do {
            let connection = try await PortviewConnection.connectQUIC(to: endpoint, pinnedCertificateSHA256: pin)
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
                    displays = hello.displays
                    activeDisplayID = display.id
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
                    if let sample = try? rebuild(frame),
                       let pixelBuffer = try? await decoder.decode(sample) {
                        renderer.render(pixelBuffer)
                    }
                case .cursorPosition(let cursor):
                    cursorNormalized = CGPoint(x: cursor.normalizedX, y: cursor.normalizedY)
                case .clipboardUpdate(let update):
                    UIPasteboard.general.string = update.text
                case .audioFrame(let audio):
                    audioPlayer.play(sampleRate: Double(audio.sampleRate), channels: UInt32(audio.channels), planarData: audio.data)
                case .viewport(let v):
                    // Host confirmed the region its frames now represent — settle the residual zoom to it.
                    frameViewport = CGRect(x: v.normalizedX, y: v.normalizedY, width: v.normalizedW, height: v.normalizedH)
                case .error(let error):
                    status = .failed("Host error: \(error.message)")
                    return
                default:
                    break
                }
            }
            if status == .streaming { status = .idle } // connection closed
            audioPlayer.stop()
            self.connection = nil
        } catch {
            status = .failed("\(error)")
            audioPlayer.stop()
            self.connection = nil
        }
    }

    private func rebuild(_ frame: VideoFrame) throws -> CMSampleBuffer {
        let encoded = try EncodedVideoSample(serialized: frame.data)
        return try VideoSampleSerializer.deserialize(encoded)
    }
}

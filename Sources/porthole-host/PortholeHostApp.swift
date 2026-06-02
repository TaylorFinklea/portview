import Foundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import PortholeProtocol
import PortholeTransport
import PortholeMedia

/// `porthole-host` — captures a display, hardware-HEVC-encodes it, and serves it over a
/// certificate-pinned TLS connection to a Porthole client (e.g. the iOS app).
///
/// Run: `swift run porthole-host`. On first run macOS will prompt for Screen-Recording
/// permission (System Settings ▸ Privacy & Security ▸ Screen Recording); grant it and re-run.
@main
struct PortholeHostApp {
    static func main() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            print("No display available to capture.")
            return
        }
        print("Display \(display.displayID): \(display.width)x\(display.height)")

        let identity = try TLSIdentity.makeEphemeralSelfSigned(commonName: "Porthole Host")
        let pinHex = try identity.certificateSHA256().map { String(format: "%02x", $0) }.joined()

        let listener = try PortholeListener(identity: identity)
        let port = try await listener.start()

        print("""

        ┌─────────────────────────────────────────────
        │ 🪟  Porthole host ready
        │ Port:  \(port.rawValue)
        │ Pin:   \(pinHex)
        │ Connect the iOS client to <your-Mac-LAN-IP>:\(port.rawValue) with that pin.
        └─────────────────────────────────────────────

        """)

        for await connection in listener.connections {
            await serve(connection, display: display)
        }
    }

    /// Run one client session: handshake, then capture → encode → serialize → send.
    static func serve(_ connection: PortholeConnection, display: SCDisplay) async {
        let width = display.width
        let height = display.height
        var server = ServerHandshake(
            displays: [DisplayInfo(id: UInt32(display.displayID), name: "Display",
                                   width: UInt32(width), height: UInt32(height), scaleX100: 100)],
            supportedCodecs: [.hevc]
        )

        handshake: for await message in connection.inbound {
            do {
                switch message {
                case .clientHello(let hello):
                    try await connection.send(.serverHello(server.handle(hello)))
                case .startSession(let start):
                    try server.handle(start)
                    break handshake
                default:
                    break
                }
            } catch {
                print("handshake error: \(error)")
                return
            }
        }
        guard server.state == .streaming else { return }
        print("Client streaming; starting capture.")

        do {
            let encoder = try VideoEncoder(width: width, height: height)
            let capture = CaptureEngine(width: width, height: height)
            try capture.start(display: display, maxFPS: 60)
            var sequence: UInt64 = 0
            for await frame in capture.frames {
                let encoded = try await encoder.encode(frame.pixelBuffer, presentationTime: frame.pts, forceKeyframe: sequence == 0)
                let sample = try VideoSampleSerializer.serialize(encoded)
                sequence += 1
                try await connection.send(.videoFrame(VideoFrame(
                    sequence: sequence,
                    ptsMicros: UInt64(max(0, CMTimeGetSeconds(frame.pts)) * 1_000_000),
                    isKeyframe: sample.isKeyframe,
                    displayID: UInt32(display.displayID),
                    width: UInt32(width), height: UInt32(height),
                    data: sample.serialized()
                )))
            }
            capture.stop()
        } catch {
            print("stream error: \(error)")
        }
    }
}

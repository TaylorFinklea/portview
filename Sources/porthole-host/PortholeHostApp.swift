import Foundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreGraphics
import ApplicationServices
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
    static func main() async {
        // ScreenCaptureKit needs Screen-Recording permission — even to enumerate displays.
        // Request/preflight it first; for a `swift run` binary the grant attaches to your
        // terminal app. If it was already declined, this returns false without re-prompting.
        guard CGRequestScreenCaptureAccess() else {
            printScreenRecordingHelp()
            return
        }

        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else {
                print("No display available to capture.")
                return
            }
            print("Display \(display.displayID): \(display.width)x\(display.height)")

            let identity = try TLSIdentity.makeEphemeralSelfSigned(commonName: "Porthole Host")
            let pinHex = try identity.certificateSHA256().map { String(format: "%02x", $0) }.joined()

            let serviceName = Host.current().localizedName ?? "Mac"
            let listener = try PortholeListener(identity: identity, serviceName: serviceName)
            let port = try await listener.start()

            let ip = NetworkInterface.primaryIPv4() ?? "<your-Mac-LAN-IP>"
            let payload = PairingPayload(host: ip, port: port.rawValue, pinHex: pinHex, name: serviceName)

            print("""

            ┌─────────────────────────────────────────────
            │ 🪟  Porthole host ready  —  \(serviceName)
            │ Address:  \(ip):\(port.rawValue)
            │ Pin:      \(pinHex)
            │ Discoverable on the LAN as "\(serviceName)" (Bonjour).
            │ Pairing URL: \(payload.urlString)
            └─────────────────────────────────────────────

            """)

            if let qr = TerminalQR.render(payload.urlString) {
                print("Scan this from the Porthole app (or use discovery + the pin above):\n")
                print(qr)
            }

            if !AXIsProcessTrusted() {
                print("ℹ️  Input control needs Accessibility permission (System Settings ▸ Privacy & Security ▸ Accessibility — enable your terminal). Viewing works without it; control won't take effect until it's granted.\n")
            }

            for await connection in listener.connections {
                await serve(connection, display: display)
            }
        } catch {
            print("Porthole host error: \(error)")
            let description = "\(error)"
            if description.contains("declined") || description.contains("TCC") || description.contains("3801") {
                printScreenRecordingHelp()
            }
        }
    }

    private static func printScreenRecordingHelp() {
        print("""

        ⚠️  Screen Recording permission is required and was not granted.

        Because `swift run` has no app identity, macOS attaches the permission to your
        TERMINAL app — and since it was declined once, the prompt won't reappear. Enable it
        manually:
          1. System Settings ▸ Privacy & Security ▸ Screen Recording.
          2. Turn on your terminal (Terminal, iTerm, Ghostty, VS Code, …). Add it with “+”
             if it isn't listed (e.g. /System/Applications/Utilities/Terminal.app).
          3. Fully quit that terminal app (Cmd-Q) and reopen it.
          4. Run `swift run porthole-host` again.

        (A signed .app bundle that requests its own Screen-Recording permission is a later
        packaging step; for now the terminal grant is the quickest path.)

        """)
    }

    /// Run one client session. A single inbound loop handles the handshake and then
    /// input messages (injected as CGEvents); video streams concurrently from a child task.
    static func serve(_ connection: PortholeConnection, display: SCDisplay) async {
        let injector = InputInjector(displayBounds: CGDisplayBounds(display.displayID))
        var server = ServerHandshake(
            displays: [DisplayInfo(id: UInt32(display.displayID), name: "Display",
                                   width: UInt32(display.width), height: UInt32(display.height), scaleX100: 100)],
            supportedCodecs: [.hevc]
        )
        var videoTask: Task<Void, Never>?

        for await message in connection.inbound {
            switch message {
            case .clientHello(let hello):
                do {
                    try await connection.send(.serverHello(server.handle(hello)))
                } catch {
                    print("handshake error: \(error)")
                    videoTask?.cancel()
                    return
                }
            case .startSession(let start):
                do { try server.handle(start) } catch { print("startSession error: \(error)"); return }
                print("Client streaming; starting capture + input.")
                videoTask = Task { await pumpVideo(connection, display: display) }
            case .pointerMove, .pointerButton, .scroll, .typeText:
                injector.handle(message)
            case .bye:
                videoTask?.cancel()
                return
            default:
                break
            }
        }
        videoTask?.cancel()
    }

    /// Capture → HEVC encode → serialize → send. The encoder is built to match the actual
    /// pixel-buffer dimensions (points vs pixels differ on Retina), and a single bad frame is
    /// skipped (re-requesting a keyframe) rather than aborting the whole stream.
    static func pumpVideo(_ connection: PortholeConnection, display: SCDisplay) async {
        let capture = CaptureEngine(width: display.width, height: display.height)
        do {
            try capture.start(display: display, maxFPS: 60)
        } catch {
            print("capture start error: \(error)")
            return
        }

        var encoder: VideoEncoder?
        var encoderWidth = 0
        var encoderHeight = 0
        var sequence: UInt64 = 0
        var needsKeyframe = true

        for await frame in capture.frames {
            let bufferWidth = CVPixelBufferGetWidth(frame.pixelBuffer)
            let bufferHeight = CVPixelBufferGetHeight(frame.pixelBuffer)
            if encoder == nil || bufferWidth != encoderWidth || bufferHeight != encoderHeight {
                do {
                    encoder = try VideoEncoder(width: bufferWidth, height: bufferHeight)
                    encoderWidth = bufferWidth
                    encoderHeight = bufferHeight
                    needsKeyframe = true
                    print("Encoder ready for \(bufferWidth)x\(bufferHeight) buffers.")
                } catch {
                    print("encoder create error: \(error)")
                    continue
                }
            }
            guard let activeEncoder = encoder else { continue }

            do {
                let encoded = try await activeEncoder.encode(frame.pixelBuffer, presentationTime: frame.pts, forceKeyframe: needsKeyframe)
                let sample = try VideoSampleSerializer.serialize(encoded)
                sequence += 1
                needsKeyframe = false
                try await connection.send(.videoFrame(VideoFrame(
                    sequence: sequence,
                    ptsMicros: UInt64(max(0, CMTimeGetSeconds(frame.pts)) * 1_000_000),
                    isKeyframe: sample.isKeyframe,
                    displayID: UInt32(display.displayID),
                    width: UInt32(bufferWidth), height: UInt32(bufferHeight),
                    data: sample.serialized()
                )))
            } catch {
                needsKeyframe = true
                if sequence == 0 { print("frame skipped (will retry as keyframe): \(error)") }
            }
        }
        capture.stop()
    }
}

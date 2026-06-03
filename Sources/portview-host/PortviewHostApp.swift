import Foundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreGraphics
import ApplicationServices
import PortviewProtocol
import PortviewTransport
import PortviewMedia

/// `portview-host` — captures a display, hardware-HEVC-encodes it, and serves it over a
/// certificate-pinned TLS connection to a Portview client (e.g. the iOS app).
///
/// Run: `swift run portview-host`. On first run macOS will prompt for Screen-Recording
/// permission (System Settings ▸ Privacy & Security ▸ Screen Recording); grant it and re-run.
@main
struct PortviewHostApp {
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
            let displays = content.displays
            guard !displays.isEmpty else {
                print("No display available to capture.")
                return
            }
            for display in displays {
                print("Display \(display.displayID): \(display.width)x\(display.height)")
            }

            let identity = try TLSIdentity.makeEphemeralSelfSigned(commonName: "Portview Host")
            let pinHex = try identity.certificateSHA256().map { String(format: "%02x", $0) }.joined()

            let serviceName = Host.current().localizedName ?? "Mac"
            let listener = try PortviewListener(quicIdentity: identity, serviceName: serviceName)
            let port = try await listener.start()

            let ip = NetworkInterface.primaryIPv4() ?? "<your-Mac-LAN-IP>"
            let payload = PairingPayload(host: ip, port: port.rawValue, pinHex: pinHex, name: serviceName)

            print("""

            ┌─────────────────────────────────────────────
            │ 🪟  Portview host ready  —  \(serviceName)
            │ Address:  \(ip):\(port.rawValue)
            │ Pin:      \(pinHex)
            │ Discoverable on the LAN as "\(serviceName)" (Bonjour).
            │ Pairing URL: \(payload.urlString)
            └─────────────────────────────────────────────

            """)

            if let qr = TerminalQR.render(payload.urlString) {
                print("Scan this from the Portview app (or use discovery + the pin above):\n")
                print(qr)
            }

            if !AXIsProcessTrusted() {
                print("ℹ️  Input control needs Accessibility permission (System Settings ▸ Privacy & Security ▸ Accessibility — enable your terminal). Viewing works without it; control won't take effect until it's granted.\n")
            }

            // Serve each accepted connection concurrently. QUIC delivers two connections per client
            // (a dead "control" one that never carries data, plus the real one) — serving them
            // concurrently means the dead connection can't block the live session. It also lets
            // multiple clients connect at once.
            for await connection in listener.connections {
                Task { await serve(connection, displays: displays) }
            }
        } catch {
            print("Portview host error: \(error)")
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
          4. Run `swift run portview-host` again.

        (A signed .app bundle that requests its own Screen-Recording permission is a later
        packaging step; for now the terminal grant is the quickest path.)

        """)
    }

    /// Run one client session. A single inbound loop handles the handshake and then
    /// input messages (injected as CGEvents); video streams concurrently from a child task.
    static func serve(_ connection: PortviewConnection, displays: [SCDisplay]) async {
        guard let firstDisplay = displays.first else { return }
        let displayInfos = displays.map {
            DisplayInfo(id: UInt32($0.displayID), name: "Display \($0.displayID)",
                        width: UInt32($0.width), height: UInt32($0.height), scaleX100: 100)
        }
        var server = ServerHandshake(displays: displayInfos, supportedCodecs: [.hevc])
        let clipboard = ClipboardSync()
        clipboard.start { text in
            Task { try? await connection.send(.clipboardUpdate(ClipboardUpdate(text: text))) }
        }
        let fileReceiver = FileReceiver()

        // Injector, capture engine, and video pump are (re)bound to the active display; switching
        // re-targets all three. `currentCapture` lets viewport (magnifier) requests re-crop the
        // live stream. All of these are touched only from this inbound loop's task.
        var injector = makeInjector(for: firstDisplay, connection: connection)
        var currentCapture: CaptureEngine?
        var videoTask: Task<Void, Never>?

        func display(forID id: UInt32) -> SCDisplay {
            displays.first { UInt32($0.displayID) == id } ?? firstDisplay
        }
        func startVideo(on display: SCDisplay) {
            videoTask?.cancel()
            injector = makeInjector(for: display, connection: connection)
            let capture = CaptureEngine(width: display.width, height: display.height)
            currentCapture = capture
            videoTask = Task { await pumpVideo(connection, display: display, capture: capture) }
            print("Streaming display \(display.displayID) (\(display.width)x\(display.height)).")
        }

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
                startVideo(on: display(forID: start.displayID))
            case .switchDisplay(let switchMessage):
                startVideo(on: display(forID: switchMessage.displayID))
            case .viewport(let viewport):
                // Magnifier: re-crop the live capture, then — only if the crop actually applied —
                // confirm the active region back to the client so it can settle its residual zoom.
                // Awaiting here (inside the inbound loop) keeps confirmations ordered with requests
                // and tied to the session's lifetime (no orphaned/racing Tasks).
                let applied = await currentCapture?.setViewport(
                    normalizedX: viewport.normalizedX, normalizedY: viewport.normalizedY,
                    normalizedW: viewport.normalizedW, normalizedH: viewport.normalizedH) ?? false
                if applied {
                    try? await connection.send(.viewport(viewport))
                }
            case .pointerMove, .pointerButton, .scroll, .typeText, .keyEvent:
                injector.handle(message)
            case .clipboardUpdate(let update):
                clipboard.applyRemote(update.text)
            case .fileOffer(let offer):
                fileReceiver.offer(offer)
            case .fileChunk(let chunk):
                fileReceiver.chunk(chunk)
            case .bye:
                clipboard.stop()
                fileReceiver.cancelAll()
                videoTask?.cancel()
                return
            default:
                break
            }
        }
        clipboard.stop()
        fileReceiver.cancelAll()
        videoTask?.cancel()
    }

    /// Build an `InputInjector` whose cursor clamping + reporting are bound to `display`.
    private static func makeInjector(for display: SCDisplay, connection: PortviewConnection) -> InputInjector {
        let injector = InputInjector(displayBounds: CGDisplayBounds(display.displayID))
        injector.onCursorMoved = { nx, ny in
            Task { try? await connection.send(.cursorPosition(CursorPosition(normalizedX: nx, normalizedY: ny))) }
        }
        return injector
    }

    /// Capture → HEVC encode → serialize → send. The encoder is built to match the actual
    /// pixel-buffer dimensions (points vs pixels differ on Retina), and a single bad frame is
    /// skipped (re-requesting a keyframe) rather than aborting the whole stream.
    static func pumpVideo(_ connection: PortviewConnection, display: SCDisplay, capture: CaptureEngine) async {
        do {
            try capture.start(display: display, maxFPS: 60)
        } catch {
            print("capture start error: \(error)")
            return
        }

        // Forward system audio concurrently with video (same connection, separate messages).
        let audioTask = Task {
            for await audio in capture.audioFrames {
                try? await connection.send(.audioFrame(AudioFrame(
                    sampleRate: audio.sampleRate, channels: audio.channels,
                    ptsMicros: audio.ptsMicros, data: audio.data)))
            }
        }
        defer { audioTask.cancel() }

        var encoder: VideoEncoder?
        var encoderWidth = 0
        var encoderHeight = 0
        var sequence: UInt64 = 0
        var needsKeyframe = true

        for await frame in capture.frames {
            if Task.isCancelled { break }  // display switch / disconnect — stop this capture promptly
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

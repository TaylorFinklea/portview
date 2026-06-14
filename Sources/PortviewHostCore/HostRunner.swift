import Foundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreGraphics
import ApplicationServices
import PortviewProtocol
import PortviewTransport
import PortviewMedia

public struct HostReadyDetails: Equatable, Sendable {
    public let serviceName: String
    public let address: String
    public let port: UInt16
    public let pinHex: String
    public let pairingURL: String

    public init(serviceName: String, address: String, port: UInt16, pinHex: String, pairingURL: String) {
        self.serviceName = serviceName
        self.address = address
        self.port = port
        self.pinHex = pinHex
        self.pairingURL = pairingURL
    }
}

public enum HostPermissionIdentity: Equatable, Sendable {
    case terminal
    case app(displayName: String)
}

public enum HostRunnerEvent: Equatable, Sendable {
    case message(String)
    case ready(HostReadyDetails)
    case accessibilityWarning(String)
    case failed(String)
}

public struct HostRunner: Sendable {
    /// Keychain service under which the host's persistent TLS identity + bound port are stored,
    /// so the pin a client pins and the port it targets both survive host restarts. The signed app
    /// and the unsigned CLI use DISTINCT items so they never contend or churn each other's pin (the
    /// app is the supported, restart-surviving path; the CLI is a developer fallback).
    static func identityKeychainService(for identity: HostPermissionIdentity) -> String {
        switch identity {
        case .app: return "dev.finklea.portview.host.identity"
        case .terminal: return "dev.finklea.portview.host.identity.cli"
        }
    }

    public init() {}

    public func events(identity: HostPermissionIdentity) -> AsyncStream<HostRunnerEvent> {
        AsyncStream { continuation in
            let task = Task {
                await run(identity: identity) { event in
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func run(
        identity: HostPermissionIdentity,
        onEvent: @escaping @Sendable (HostRunnerEvent) -> Void
    ) async {
        guard CGRequestScreenCaptureAccess() else {
            onEvent(.failed(Self.screenRecordingHelp(for: identity)))
            return
        }

        do {
            let content = try await SCShareableContent.current
            let displays = content.displays
            guard !displays.isEmpty else {
                onEvent(.failed("No display available to capture."))
                return
            }
            for display in displays {
                onEvent(.message("Display \(display.displayID): \(display.width)x\(display.height)"))
            }

            // Persisted identity: a stable pin across restarts (mints + stores on first run).
            let keychainService = Self.identityKeychainService(for: identity)
            let persistedIdentity = try TLSIdentity.loadOrCreatePersistent(service: keychainService)
            let tlsIdentity = persistedIdentity.identity
            let pinHex = try tlsIdentity.certificateSHA256().map { String(format: "%02x", $0) }.joined()
            if !persistedIdentity.persistent {
                onEvent(.message("⚠️ Couldn't persist the host identity to the keychain; this pairing's pin will change when the host restarts (re-pair after a restart)."))
            }

            let serviceName = Host.current().localizedName ?? "Mac"
            // Re-bind the persisted port so a saved pairing's host:port stays valid; persist whatever
            // port actually bound (first run, or a fallback when the preferred port was taken).
            let (listener, port) = try await Self.startListener(
                identity: tlsIdentity, serviceName: serviceName, preferredPort: persistedIdentity.port)
            defer { listener.cancel() }
            if let preferred = persistedIdentity.port, preferred != port {
                onEvent(.message("ℹ️ Preferred port \(preferred) was unavailable; bound \(port) instead. Reconnect from the QR/pairing URL to refresh saved pairings."))
            }
            if persistedIdentity.persistent, !TLSIdentity.persistPort(port, service: keychainService) {
                onEvent(.message("⚠️ Bound port \(port) but couldn't persist it; the port may change on the next restart."))
            }

            let ip = NetworkInterface.primaryIPv4() ?? "<your-Mac-LAN-IP>"
            let payload = PairingPayload(host: ip, port: port, pinHex: pinHex, name: serviceName)
            let details = HostReadyDetails(
                serviceName: serviceName,
                address: ip,
                port: port,
                pinHex: pinHex,
                pairingURL: payload.urlString
            )

            onEvent(.ready(details))
            onEvent(.message(Self.readyMessage(details)))

            if let qr = TerminalQR.render(payload.urlString) {
                onEvent(.message("Scan this from the Portview app (or use discovery + the pin above):\n\n\(qr)"))
            }

            if !AXIsProcessTrusted() {
                onEvent(Self.accessibilityWarningEvent(for: identity))
            }

            let sendableDisplays = SendableDisplays(displays)
            await withTaskCancellationHandler {
                await Self.serveConnections(listener.connections) { connection in
                    await Self.serve(connection, displays: sendableDisplays)
                }
            } onCancel: {
                listener.cancel()
            }
        } catch {
            onEvent(.failed("Portview host error: \(error)"))
            let description = "\(error)"
            if description.contains("declined") || description.contains("TCC") || description.contains("3801") {
                onEvent(.failed(Self.screenRecordingHelp(for: identity)))
            }
        }
    }

    /// Start the QUIC listener, preferring `preferredPort` for a stable endpoint. If that port is
    /// unavailable, fall back to an OS-assigned one (so the host always starts). Returns the
    /// listener and the actually-bound port.
    static func startListener(
        identity: TLSIdentity,
        serviceName: String,
        preferredPort: UInt16?
    ) async throws -> (listener: PortviewListener, port: UInt16) {
        if let preferredPort {
            do {
                let listener = try PortviewListener(quicIdentity: identity, serviceName: serviceName, port: preferredPort)
                do {
                    let port = try await listener.start()
                    return (listener, port.rawValue)
                } catch {
                    listener.cancel()  // release the partially-started listener before falling back
                    throw error
                }
            } catch {
                print("Preferred port \(preferredPort) unavailable (\(error)); using an OS-assigned port.")
            }
        }
        let listener = try PortviewListener(quicIdentity: identity, serviceName: serviceName)
        let port = try await listener.start()
        return (listener, port.rawValue)
    }

    public static func readyMessage(_ details: HostReadyDetails) -> String {
        """

        ┌─────────────────────────────────────────────
        │ 🪟  Portview host ready  —  \(details.serviceName)
        │ Address:  \(details.address):\(details.port)
        │ Pin:      \(details.pinHex)
        │ Discoverable on the LAN as "\(details.serviceName)" (Bonjour).
        │ Pairing URL: \(details.pairingURL)
        └─────────────────────────────────────────────

        """
    }

    public static func screenRecordingHelp(for identity: HostPermissionIdentity) -> String {
        switch identity {
        case .terminal:
            return """

            ⚠️  Screen Recording permission is required and was not granted.

            Because `swift run` has no app identity, macOS attaches the permission to your
            TERMINAL app — and since it was declined once, the prompt won't reappear. For the
            normal device-test path, run PortviewHost.app so the grant attaches to Portview.

            Developer CLI fallback:
              1. System Settings ▸ Privacy & Security ▸ Screen Recording.
              2. Turn on your terminal (Terminal, iTerm, Ghostty, VS Code, …). Add it with “+”
                 if it isn't listed (e.g. /System/Applications/Utilities/Terminal.app).
              3. Fully quit that terminal app (Cmd-Q) and reopen it.
              4. Run `swift run portview-host` again.

            """
        case .app(let displayName):
            return """

            ⚠️  Screen Recording permission is required and was not granted.

            Enable \(displayName).app in System Settings ▸ Privacy & Security ▸ Screen Recording.
            If macOS just prompted you, grant access, fully quit \(displayName).app, and reopen it.

            """
        }
    }

    public static func accessibilityHelp(for identity: HostPermissionIdentity) -> String {
        switch identity {
        case .terminal:
            return "ℹ️  Input control needs Accessibility permission (System Settings ▸ Privacy & Security ▸ Accessibility — enable your terminal). Viewing works without it; control won't take effect until it's granted."
        case .app(let displayName):
            return "ℹ️  Input control needs Accessibility permission (System Settings ▸ Privacy & Security ▸ Accessibility — enable \(displayName).app). Viewing works without it; control won't take effect until it's granted."
        }
    }

    public static func accessibilityWarningEvent(for identity: HostPermissionIdentity) -> HostRunnerEvent {
        .accessibilityWarning(Self.accessibilityHelp(for: identity))
    }

    static func serveConnections<Connection: Sendable>(
        _ connections: AsyncStream<Connection>,
        serve: @escaping @Sendable (Connection) async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for await connection in connections {
                if Task.isCancelled { break }
                group.addTask { await serve(connection) }
            }
            group.cancelAll()
        }
    }

    /// Run one client session. A single inbound loop handles the handshake and then
    /// input messages (injected as CGEvents); video streams concurrently from a child task.
    private static func serve(_ connection: PortviewConnection, displays: SendableDisplays) async {
        await withTaskCancellationHandler {
            await serveSession(connection, displays: displays)
        } onCancel: {
            connection.close()
        }
    }

    private static func serveSession(_ connection: PortviewConnection, displays: SendableDisplays) async {
        let displays = displays.values
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
        defer {
            clipboard.stop()
            fileReceiver.cancelAll()
            videoTask?.cancel()
            currentCapture?.stop()
            connection.close()
        }

        func display(forID id: UInt32) -> SCDisplay {
            displays.first { UInt32($0.displayID) == id } ?? firstDisplay
        }
        func startVideo(on display: SCDisplay) {
            videoTask?.cancel()
            injector = makeInjector(for: display, connection: connection)
            let capture = CaptureEngine(width: display.width, height: display.height)
            currentCapture = capture
            videoTask = Task { await pumpVideo(connection, display: display, capture: capture) }
            print("Streaming display \(display.displayID) source \(display.width)x\(display.height).")
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
                return
            default:
                break
            }
        }
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
        var stats = QualityStatsAccumulator()

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
                let cropRequestedKeyframe = await capture.consumeKeyframeRequest()
                let forceKeyframe = needsKeyframe || cropRequestedKeyframe
                let encodeStart = ProcessInfo.processInfo.systemUptime
                let encoded = try await activeEncoder.encode(frame.pixelBuffer, presentationTime: frame.pts, forceKeyframe: forceKeyframe)
                let encodeMs = (ProcessInfo.processInfo.systemUptime - encodeStart) * 1_000.0
                let sample = try VideoSampleSerializer.serialize(encoded)
                let payload = sample.serialized()
                sequence += 1
                needsKeyframe = false
                stats.recordFrame(byteCount: payload.count, isKeyframe: sample.isKeyframe, encodeMs: encodeMs)
                try await connection.send(.videoFrame(VideoFrame(
                    sequence: sequence,
                    ptsMicros: UInt64(max(0, CMTimeGetSeconds(frame.pts)) * 1_000_000),
                    isKeyframe: sample.isKeyframe,
                    displayID: UInt32(display.displayID),
                    width: UInt32(bufferWidth), height: UInt32(bufferHeight),
                    data: payload
                )))
                if let quality = stats.snapshotIfDue(
                    displayID: UInt32(display.displayID),
                    encoderWidth: encoderWidth,
                    encoderHeight: encoderHeight,
                    configuredBitrate: activeEncoder.averageBitRate,
                    viewport: await capture.currentViewport()
                ) {
                    try? await connection.send(.qualityStats(quality))
                }
            } catch {
                needsKeyframe = true
                if sequence == 0 { print("frame skipped (will retry as keyframe): \(error)") }
            }
        }
        capture.stop()
    }
}

private struct SendableDisplays: @unchecked Sendable {
    // ScreenCaptureKit does not annotate SCDisplay as Sendable. We only share these immutable
    // display descriptors with per-connection tasks; capture mutation happens inside SCStream.
    let values: [SCDisplay]

    init(_ values: [SCDisplay]) {
        self.values = values
    }
}

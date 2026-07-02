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
    /// A client finished the handshake and began a session (carries the device's reported name).
    case deviceConnected(id: String, name: String)
    /// A client's session ended.
    case deviceDisconnected(id: String)
    /// Periodic live-session telemetry for the connected-device card.
    case sessionStats(HostSessionStats)
    /// The 6-digit SAS pairing code to display on the host HUD (never logged). Cleared by the app on
    /// connect/timeout/stop.
    case sasCode(String)
    /// A client sent a valid authenticated pairing confirmation (Guardrail E). A positive "✓ a client
    /// confirmed" signal only — it must NOT close the (single, shared) pairing window; the window
    /// closes via the pinned re-dial's `.deviceConnected`, the app timeout, the cap, or stop.
    case sasConfirmed
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

    public func events(identity: HostPermissionIdentity, control: HostControl? = nil,
                       sasControl: SASPairingControl? = nil) -> AsyncStream<HostRunnerEvent> {
        AsyncStream { continuation in
            let task = Task {
                await run(identity: identity, control: control, sasControl: sasControl) { event in
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func run(
        identity: HostPermissionIdentity,
        control: HostControl? = nil,
        sasControl: SASPairingControl? = nil,
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

            let registry = DisplayRegistry(displays)
            let hostCertBytes = (try? tlsIdentity.certificateSHA256()).map { [UInt8]($0) } ?? []
            // Host-side authority (not just the client-side UX gate above): drop input injection
            // while locked, regardless of what any connected client sends. Seed from the current
            // state in case the Mac is already locked when this session starts.
            InputInjector.paused = LockMonitor.currentlyLocked()
            // Tell connected clients when the host screen locks/unlocks so they can pause the live view
            // (a locked Mac captures the secure desktop / blank, not the user's content).
            let lockMonitor = LockMonitor { locked in
                InputInjector.paused = locked
                control?.broadcast(.hostLockStatus(HostLockStatus(locked: locked)))
                onEvent(.message(locked ? "🔒 Screen locked — live view paused for connected clients."
                                        : "🔓 Screen unlocked — live view resumed."))
            }
            lockMonitor.start()
            defer { lockMonitor.stop() }
            await withTaskCancellationHandler {
                await withTaskGroup(of: Void.self) { group in
                    // Re-advertise displays when the configuration changes (monitor connected/woken/removed).
                    group.addTask {
                        await Self.refreshDisplaysLoop(registry: registry, control: control, emit: onEvent)
                    }
                    group.addTask {
                        await Self.serveConnections(listener.connections) { connection in
                            await Self.serve(connection, registry: registry, hostCertSHA256: hostCertBytes,
                                             emit: onEvent, control: control, sas: sasControl)
                        }
                    }
                    // serveConnections returns only on cancellation; tear down the refresh loop with it.
                    await group.next()
                    group.cancelAll()
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

    /// Map ScreenCaptureKit displays to the wire `DisplayInfo` advertised to clients. Used both at
    /// handshake (`ServerHello`) and by the runtime refresh loop (`DisplaysUpdate`) so both paths
    /// describe a display identically.
    static func displayInfos(from displays: [SCDisplay]) -> [DisplayInfo] {
        displays.map {
            DisplayInfo(id: UInt32($0.displayID), name: "Display \($0.displayID)",
                        width: UInt32($0.width), height: UInt32($0.height), scaleX100: 100)
        }
    }

    /// Whether the display configuration changed enough to re-advertise. Order-independent (the OS may
    /// reorder the list) but sensitive to identity, count, and dimensions — so a monitor connecting,
    /// waking, being removed, or changing resolution triggers a `DisplaysUpdate`, while a bare reorder
    /// of the same set does not.
    static func displaysChanged(from old: [DisplayInfo], to new: [DisplayInfo]) -> Bool {
        old.sorted { $0.id < $1.id } != new.sorted { $0.id < $1.id }
    }

    /// Periodically re-read the host's displays and re-advertise to connected clients when the set
    /// changes. The display list is otherwise snapshotted once at launch, so a monitor connected/woken
    /// after the host started would never appear (and the client's switcher would stay hidden) without
    /// this. Polls `SCShareableContent.current` (the same source as the launch snapshot); a momentarily
    /// empty snapshot is ignored so a transient read can't blank the registry.
    static func refreshDisplaysLoop(
        registry: DisplayRegistry,
        control: HostControl?,
        emit: @escaping @Sendable (HostRunnerEvent) -> Void,
        interval: Duration = .seconds(2)
    ) async {
        var last = displayInfos(from: await registry.current())
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { break }
            guard let content = try? await SCShareableContent.current else { continue }
            let displays = content.displays
            guard !displays.isEmpty else { continue }
            let infos = displayInfos(from: displays)
            guard displaysChanged(from: last, to: infos) else { continue }
            last = infos
            await registry.set(displays)
            emit(.message("Displays changed: \(infos.count) display(s) available."))
            control?.broadcast(.displaysUpdate(DisplaysUpdate(displays: infos)))
        }
    }

    /// Default ceiling on concurrently-served connections. A legit host serves one streaming client
    /// plus a few transient SAS preambles; this caps a connection flood (Guardrail C). Each accepted
    /// connection still spawns a task that reads its first message before doing anything, and a SAS
    /// preamble now lingers ~25s awaiting its confirm — so an UNBOUNDED group let an attacker hold
    /// arbitrarily many tasks. With the cap, excess connections apply backpressure (queue) instead.
    static let maxConcurrentConnections = 16

    static func serveConnections<Connection: Sendable>(
        _ connections: AsyncStream<Connection>,
        maxConcurrent: Int = maxConcurrentConnections,
        serve: @escaping @Sendable (Connection) async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for await connection in connections {
                if Task.isCancelled { break }
                // Hold at most `maxConcurrent` serve tasks in flight; wait for a slot before adding more.
                if running >= maxConcurrent {
                    await group.next()
                    running -= 1
                }
                group.addTask { await serve(connection) }
                running += 1
            }
            group.cancelAll()
        }
    }

    /// Carries a mutable `AsyncIterator` across the unstructured read task below. Only one task
    /// ever touches `iterator` at a time (the race's winner is read back into the caller's `inout`
    /// once it settles), so the lack of internal synchronization is safe despite `@unchecked Sendable`.
    private final class MessageIteratorBox: @unchecked Sendable {
        var iterator: AsyncStream<AnyMessage>.AsyncIterator
        init(_ iterator: AsyncStream<AnyMessage>.AsyncIterator) { self.iterator = iterator }
    }

    /// Race an inbound read against `deadline`, returning `nil` on timeout instead of blocking
    /// indefinitely. `AsyncStream.next()` isn't itself cancellation-aware, so the loser of the race
    /// (typically the read, when nothing arrives) is left running unstructured in the background
    /// rather than awaited — it's harmless and will resolve once the stream eventually yields or
    /// finishes. Used to bound serve paths' first-message read, which previously had no
    /// application-level deadline (only the ~30s QUIC idle timeout), letting an idle/phantom
    /// connection hold a serve-cap slot for the full ~30s.
    static func nextMessage(
        from iterator: inout AsyncStream<AnyMessage>.AsyncIterator,
        deadline: Duration
    ) async -> AnyMessage? {
        let box = MessageIteratorBox(iterator)
        let gate = SingleResumeGate()
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<AnyMessage?, Never>) in
            Task {
                let message = await box.iterator.next()
                if await gate.tryResume() { continuation.resume(returning: message) }
            }
            Task {
                try? await Task.sleep(for: deadline)
                if await gate.tryResume() { continuation.resume(returning: nil) }
            }
        }
        iterator = box.iterator
        return result
    }

    /// Guards a `CheckedContinuation` against a double-resume when two racing tasks may both try
    /// to complete it; only the first `tryResume()` call succeeds.
    private actor SingleResumeGate {
        private var resumed = false
        func tryResume() -> Bool {
            guard !resumed else { return false }
            resumed = true
            return true
        }
    }

    /// Run one client session. A single inbound loop handles the handshake and then
    /// input messages (injected as CGEvents); video streams concurrently from a child task.
    private static func serve(
        _ connection: PortviewConnection,
        registry: DisplayRegistry,
        hostCertSHA256: [UInt8] = [],
        emit: @escaping @Sendable (HostRunnerEvent) -> Void = { _ in },
        control: HostControl? = nil,
        sas: SASPairingControl? = nil
    ) async {
        await withTaskCancellationHandler {
            await serveSession(connection, registry: registry, hostCertSHA256: hostCertSHA256,
                               emit: emit, control: control, sas: sas)
        } onCancel: {
            connection.close()
        }
    }

    private static func serveSession(
        _ connection: PortviewConnection,
        registry: DisplayRegistry,
        hostCertSHA256: [UInt8] = [],
        emit: @escaping @Sendable (HostRunnerEvent) -> Void = { _ in },
        control: HostControl? = nil,
        sas: SASPairingControl? = nil
    ) async {
        guard let firstDisplay = await registry.current().first else { connection.close(); return }

        // Peek the first message to LOCK this connection's role BEFORE building any session
        // scaffolding. An SAS-preamble connection (first message = client commit) is UNPINNED (TOFU)
        // and must never reach the clipboard / input-injector / capture / file path — trust is decided
        // by the SAS code comparison, after which the client re-dials pinned. (v2 review CRITICAL-3.)
        // Bounded by a short deadline (not just the ~30s QUIC idle timeout): an idle or
        // double-delivered "phantom" connection would otherwise hold a serve-cap slot for the full
        // ~30s, starving a legit client.
        var inbound = connection.inbound.makeAsyncIterator()
        guard let firstMessage = await nextMessage(from: &inbound, deadline: .seconds(5)) else {
            connection.close(); return
        }
        if case .sasClientCommit(let commit) = firstMessage {
            await serveSASPreamble(connection, clientCommit: commit, inbound: &inbound,
                                   hostCertSHA256: hostCertSHA256, sas: sas, emit: emit)
            return
        }

        var server = ServerHandshake(displays: Self.displayInfos(from: await registry.current()), supportedCodecs: [.hevc])
        let clipboard = ClipboardSync()
        clipboard.start { text in
            Task { try? await connection.send(.clipboardUpdate(ClipboardUpdate(text: text))) }
        }
        let fileReceiver = FileReceiver()
        // Identifies this session for the host UI; set once the client handshake names the device.
        var connectedDeviceID: String?
        // Client-requested stream params (StartSession), honored by capture + encoder and reused
        // when the display is switched mid-session.
        var requestedFPS = 60
        var requestedBitrate: Int?

        // Injector, capture engine, and video pump are (re)bound to the active display; switching
        // re-targets all three. `currentCapture` lets viewport (magnifier) requests re-crop the
        // live stream. All of these are touched only from this inbound loop's task.
        // One ordered, coalescing lane for cursor reports across this whole connection (survives display
        // switches), so confirmations can't reorder/back-step the client's cursor-follow.
        let cursorPump = CursorReportPump(connection: connection)
        var injector = makeInjector(for: firstDisplay, cursorPump: cursorPump)
        var currentCapture: CaptureEngine?
        var videoTask: Task<Void, Never>?
        defer {
            clipboard.stop()
            fileReceiver.cancelAll()
            videoTask?.cancel()
            currentCapture?.stop()
            cursorPump.finish()
            connection.close()
            if let connectedDeviceID {
                control?.deregister(connectedDeviceID)
                emit(.deviceDisconnected(id: connectedDeviceID))
            }
        }

        func display(forID id: UInt32) async -> SCDisplay {
            await registry.current().first { UInt32($0.displayID) == id } ?? firstDisplay
        }
        func startVideo(on display: SCDisplay) {
            videoTask?.cancel()
            injector = makeInjector(for: display, cursorPump: cursorPump)
            let capture = CaptureEngine(width: display.width, height: display.height)
            currentCapture = capture
            let fps = requestedFPS
            let bitrate = requestedBitrate
            videoTask = Task { await pumpVideo(connection, display: display, capture: capture, fps: fps, bitrate: bitrate, emit: emit) }
            print("Streaming display \(display.displayID) source \(display.width)x\(display.height).")
        }

        var pendingMessage: AnyMessage? = firstMessage
        while let message = pendingMessage {
            switch message {
            case .clientHello(let hello):
                do {
                    try await connection.send(.serverHello(server.handle(hello)))
                    if connectedDeviceID == nil {
                        // Identify the session per-connection (not by the device's stable id): on a
                        // reconnect the old session's disconnect must not evict the new one's entry.
                        let sessionID = UUID().uuidString
                        connectedDeviceID = sessionID
                        control?.register(sessionID, connection)
                        emit(.deviceConnected(id: sessionID, name: hello.deviceName))
                        // Seed this client with the current lock state (the live broadcast only reaches
                        // already-connected clients), so one that connects while locked pauses at once.
                        if LockMonitor.currentlyLocked() {
                            try? await connection.send(.hostLockStatus(HostLockStatus(locked: true)))
                        }
                    }
                } catch {
                    print("handshake error: \(error)")
                    videoTask?.cancel()
                    return
                }
            case .startSession(let start):
                do { try server.handle(start) } catch { print("startSession error: \(error)"); return }
                requestedFPS = StreamParameters.captureFPS(requested: start.maxFPS)
                requestedBitrate = StreamParameters.encoderBitrate(requested: start.targetBitrate)
                startVideo(on: await display(forID: start.displayID))
            case .switchDisplay(let switchMessage):
                startVideo(on: await display(forID: switchMessage.displayID))
            case .viewport(let viewport):
                // Magnifier: re-crop the live capture. The viewport now travels in every VideoFrame,
                // so no separate echo is needed — just apply the crop.
                _ = await currentCapture?.setViewport(
                    normalizedX: viewport.normalizedX, normalizedY: viewport.normalizedY,
                    normalizedW: viewport.normalizedW, normalizedH: viewport.normalizedH)
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
            case .ping(let ping):
                let hostUptimeMicros = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000)
                try? await connection.send(.pong(Pong(sendMicros: ping.sendMicros, hostUptimeMicros: hostUptimeMicros)))
            case .pong:
                break
            default:
                break
            }
            pendingMessage = await inbound.next()
        }
    }

    /// Serve the SAS pairing PREAMBLE on an unpinned connection: two-sided commit-then-reveal, then
    /// derive + emit the 6-digit code for the host HUD. Builds NONE of the streaming scaffolding
    /// (no clipboard/injector/capture/file). Only engages while a user-opened pairing window is live;
    /// each engagement counts against the window-scoped attempt cap. The connection carries only the
    /// SAS messages and is torn down here; the client compares the code and re-dials pinned.
    /// `internal` (not `private`) so the loopback integration test can drive it directly.
    static func serveSASPreamble(
        _ connection: PortviewConnection,
        clientCommit: SASClientCommit,
        inbound: inout AsyncStream<AnyMessage>.AsyncIterator,
        hostCertSHA256: [UInt8],
        sas: SASPairingControl?,
        emit: @escaping @Sendable (HostRunnerEvent) -> Void
    ) async {
        defer { connection.close() }
        // Gate: only pair during a user-opened window, and cap attempts within it.
        guard let sas, await sas.isOpen() else { return }
        guard await sas.registerAttempt() else { await sas.closeWindow(); return }

        // Host: fresh nonce + commit, sent before any reveal.
        let hostNonce = SASCode.randomNonce()
        let hostCommit = SASCode.commit(nonce: hostNonce, role: .host, certSHA256: hostCertSHA256)
        do { try await connection.send(.sasHostCommit(SASHostCommit(commit: hostCommit))) } catch { return }

        // Client reveal must come next; verify it against the client commit before using the nonce.
        // Deadline-bounded (rather than left to the ~30s QUIC idle timeout) so an idle/phantom
        // preamble connection doesn't hold its slot for the full ~30s.
        guard let next = await nextMessage(from: &inbound, deadline: .seconds(5)),
              case .sasClientReveal(let reveal) = next else { return }
        guard SASCode.verify(commitment: clientCommit.commit, nonce: reveal.nonce,
                             role: .client, certSHA256: hostCertSHA256) else { return }

        // Reveal the host nonce, then both sides derive the same code; display it for the user.
        do { try await connection.send(.sasHostReveal(SASHostReveal(nonce: hostNonce))) } catch { return }
        let code = SASCode.derive(clientNonce: reveal.nonce, hostNonce: hostNonce, certSHA256: hostCertSHA256)
        emit(.sasCode(code))

        // Guardrail E (optional, best-effort): read EXACTLY ONE more message — the client's
        // authenticated confirmation that the user matched. Bounded by a timeout task that closes the
        // connection (so `inbound.next()` can't hang on a silent-but-connected peer); the timeout is
        // under the QUIC idle (30s) so the held connection is realistically still alive. A valid
        // confirm emits `.sasConfirmed` (a positive signal only — it does NOT close the window); any
        // other outcome (timeout / wrong mac / disconnect / other message) emits nothing. The attempt
        // was already counted at engagement start, so a forged confirm can't affect the cap/lockout.
        let confirmTimeout = Task { try? await Task.sleep(for: .seconds(25)); connection.close() }
        defer { confirmTimeout.cancel() }
        guard case .sasClientConfirm(let confirm)? = await inbound.next() else { return }
        if SASCode.verifyConfirmation(confirm.mac, clientNonce: reveal.nonce, hostNonce: hostNonce,
                                      certSHA256: hostCertSHA256) {
            emit(.sasConfirmed)
        }
    }

    /// Build an `InputInjector` whose cursor clamping + reporting are bound to `display`. Cursor reports
    /// go through the connection's ordered `cursorPump` (not a detached Task per report) so they reach
    /// the client monotonically.
    private static func makeInjector(for display: SCDisplay, cursorPump: CursorReportPump) -> InputInjector {
        let injector = InputInjector(displayBounds: CGDisplayBounds(display.displayID))
        injector.onCursorMoved = { nx, ny in cursorPump.report(nx, ny) }
        return injector
    }

    /// Capture → HEVC encode → serialize → send. The encoder is built to match the actual
    /// pixel-buffer dimensions (points vs pixels differ on Retina), and a single bad frame is
    /// skipped (re-requesting a keyframe) rather than aborting the whole stream.
    static func pumpVideo(
        _ connection: PortviewConnection,
        display: SCDisplay,
        capture: CaptureEngine,
        fps: Int = 60,
        bitrate: Int? = nil,
        emit: @escaping @Sendable (HostRunnerEvent) -> Void = { _ in }
    ) async {
        do {
            try capture.start(display: display, maxFPS: fps)
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
                    encoder = try VideoEncoder(width: bufferWidth, height: bufferHeight, averageBitRate: bitrate)
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
                // Tag with the region captured WITH this buffer (not the live viewport, which may have
                // re-cropped since this buffer was produced) so the client maps the zoom window into the
                // region the pixels actually show — no wrong-content flash on re-crop.
                let viewport = frame.region
                try await connection.send(.videoFrame(VideoFrame(
                    sequence: sequence,
                    ptsMicros: UInt64(max(0, CMTimeGetSeconds(frame.pts)) * 1_000_000),
                    isKeyframe: sample.isKeyframe,
                    displayID: UInt32(display.displayID),
                    width: UInt32(bufferWidth), height: UInt32(bufferHeight),
                    data: payload,
                    viewportNormalizedX: viewport.minX, viewportNormalizedY: viewport.minY,
                    viewportNormalizedW: viewport.width, viewportNormalizedH: viewport.height
                )))
                if let quality = stats.snapshotIfDue(
                    displayID: UInt32(display.displayID),
                    encoderWidth: encoderWidth,
                    encoderHeight: encoderHeight,
                    configuredBitrate: activeEncoder.averageBitRate,
                    viewport: await capture.currentViewport()
                ) {
                    try? await connection.send(.qualityStats(quality))
                    emit(.sessionStats(HostSessionStats(
                        throughputMbps: quality.encodedMbps,
                        fps: quality.fps,
                        encodeMs: quality.averageEncodeMs,
                        displayWidth: display.width,
                        displayHeight: display.height)))
                }
            } catch {
                // Drop the wedged encoder so the next frame rebuilds a fresh VideoToolbox session
                // (the startup path); keeping it would re-enter the same broken session every frame.
                encoder = nil
                needsKeyframe = true
                if sequence == 0 { print("frame skipped (will rebuild encoder): \(error)") }
            }
        }
        capture.stop()
    }
}

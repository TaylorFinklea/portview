// SPDX-License-Identifier: Apache-2.0
import Foundation
import Network
import UIKit
import CoreMedia
import os
import PortviewProtocol
import PortviewTransport
import PortviewMedia
import PortviewClientCore

private let logger = Logger(subsystem: "dev.finklea.portview", category: "video")

/// Drives a Portview client session: connect (cert-pinned) → handshake → receive video
/// frames → rebuild sample buffers → enqueue for display. If a live session drops, it re-binds the
/// host over Bonjour (surviving a LAN IP change) before giving up — the `.reconnecting` state.
@MainActor
final class SessionViewModel: ObservableObject {
    enum Status: Equatable {
        case idle, connecting, streaming, reconnecting, failed(String)
    }

    @Published var status: Status = .idle
    /// Non-nil while pairing a discovered Mac via the 6-digit SAS code (drives the entry sheet).
    @Published var sasPairing: SASPairingState?
    /// Latest cursor position reported by the host, normalized to the display (0…1).
    @Published var cursorNormalized = CGPoint(x: 0.5, y: 0.5)
    /// Displays the host offered (from ServerHello) and which one is currently streaming.
    @Published var displays: [DisplayInfo] = []
    @Published var activeDisplayID: UInt32 = 0
    /// Transient status of an in-flight file push/receive (nil when none).
    @Published var transferStatus: String?
    /// A file received from the Mac (Mac→iPhone transfer), ready to share/save; nil when none.
    @Published var receivedFile: ReceivedFile?
    private let incomingFiles = IncomingFileTransfers()
    /// Normalized region of the display the host's current frames represent (the magnifier crop).
    /// Updated when the host confirms a viewport; the client renders the residual zoom against it.
    @Published var frameViewport = CGRect(x: 0, y: 0, width: 1, height: 1)
    @Published var qualityDiagnostics = QualityDiagnostics()
    /// True when the host reports its screen is locked — the captured content is the secure desktop /
    /// blank, so the client pauses the live view and shows a "capture paused" overlay.
    @Published var hostLocked = false
    /// The name of the Mac this session is bound to (for reconnect status copy); nil before connect.
    @Published private(set) var hostName: String?
    /// Set when a stream succeeds: the host to remember, carrying the connection's resolved concrete
    /// IP (so discovered Macs persist and a moved saved Mac's IP refreshes). Nil otherwise.
    @Published private(set) var connectedHostToSave: PairingPayload?
    private var sessionName: String?
    private var sessionPinHex: String?
    private var qualityTracker = QualityDiagnosticsTracker()
    /// Latest Ping/Pong round-trip time (µs), reported in `ClientFeedback`; 0 until the first Pong
    /// of a connection lands.
    private var latestRTTMicros: UInt32 = 0
    // Re-cropping is now gated by edge-hysteresis (`requestViewport`), so this can stay prompt (150ms):
    // a re-crop fires immediately when you move to a new region, but in-region pans don't re-crop at
    // all — keeping SCStream.updateConfiguration (which hiccups capture fps) rare without the laggy
    // "paints a second later" of a blunt throttle.
    private lazy var viewportRequests = ViewportRequestScheduler { [weak self] rect in
        guard let self else { return }
        self.send(.viewport(Viewport(
            displayID: self.activeDisplayID,
            normalizedX: rect.minX, normalizedY: rect.minY,
            normalizedW: rect.width, normalizedH: rect.height)))
    }
    let renderer = MetalVideoRenderer()
    private let decoder = VideoDecoder()
    private let audioPlayer = AudioPlayer()
    /// Decoder-resync policy: requests a keyframe (rate-limited) when a coalesced-away frame or
    /// a decode failure breaks the HEVC delta chain — without it, one dropped frame froze the
    /// picture permanently (2026-07-16). Reset per session attempt and per display switch.
    private var keyframeRecovery = KeyframeRecovery()
    private var task: Task<Void, Never>?
    private var connection: PortviewClientSession?
    /// Ordered outbound input lane bound to `connection` (created/torn down with it via bind/unbind).
    private var outboundPump: OutboundInputPump?
    /// Mac display size in points (from ServerHello); used to predict the cursor locally and to
    /// letterbox-correct the client's zoom/pan math.
    @Published private(set) var displaySize = CGSize(width: 1, height: 1)
    /// Must match the host's InputInjector sensitivity so the predicted cursor tracks the real one.
    private let inputSensitivity: CGFloat = 1.5

    private var hasFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    /// Total time to keep trying to re-bind a dropped session before failing.
    private static let reconnectWindow: TimeInterval = 30
    /// How long each rediscovery pass waits for the host to reappear on Bonjour.
    private static let rediscoverTimeout: Duration = .seconds(6)

    func connect(host: String, port: UInt16, pinHex: String) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            status = .failed("Invalid port.")
            return
        }
        start(endpoints: [.hostPort(host: NWEndpoint.Host(host), port: nwPort)],
              pinHex: pinHex, reconnectName: host)
    }

    /// Connect to a Bonjour-discovered host (user still supplies the pin).
    func connect(to host: DiscoveredHost, pinHex: String) {
        start(endpoints: [host.endpoint], pinHex: pinHex, reconnectName: host.name)
    }

    /// Connect from a scanned QR pairing payload, preferring a live Bonjour endpoint for the
    /// advertised host name while retaining the QR's address as an off-LAN fallback.
    func connect(payload: PairingPayload, discovered: [DiscoveredHost]) {
        let endpoints = ReconnectPlanning.qrPairingCandidates(payload: payload, discovered: discovered)
        guard !endpoints.isEmpty else {
            status = .failed("Invalid port.")
            return
        }
        start(endpoints: endpoints,
              pinHex: payload.pinHex, reconnectName: payload.name ?? payload.host)
    }

    /// Reconnect a saved Mac, preferring its live Bonjour endpoint (survives a LAN IP change) and
    /// falling back to the saved host:port. The saved pin is unchanged, so cert pinning still
    /// gates the connection regardless of which candidate wins.
    func reconnect(saved: SavedHost, discovered: [DiscoveredHost]) {
        start(endpoints: saved.reconnectEndpoints(among: discovered),
              pinHex: saved.pinHex, reconnectName: saved.name)
    }

    // MARK: - SAS (6-digit) pairing

    /// Owns the SAS pairing sub-flow (preamble connection, derived code, confirm secret); `sasPairing`
    /// mirrors its state for the entry sheet, and on a match it calls back into `start` to re-dial
    /// pinned with the captured cert hash.
    private let pairingCoordinator = SASClientCoordinator()

    init() {
        pairingCoordinator.onStateChange = { [weak self] state in self?.sasPairing = state }
        pairingCoordinator.startPinnedSession = { [weak self] endpoint, pinHex, name in
            self?.start(endpoints: [endpoint], pinHex: pinHex, reconnectName: name)
        }
    }

    /// Begin SAS pairing for a Bonjour-discovered Mac (no pin typed). Cancels any live session task,
    /// then hands the commit→reveal→derive→confirm flow to the coordinator.
    func beginSASPairing(to host: DiscoveredHost) {
        task?.cancel()
        pairingCoordinator.begin(endpoint: host.endpoint, name: host.name)
    }

    /// The user typed the code the Mac shows; the coordinator decides match/mismatch/expired.
    func submitSASCode(_ typed: String) {
        pairingCoordinator.submitCode(typed)
    }

    func cancelSASPairing() {
        pairingCoordinator.cancel()
    }

    private func start(endpoints: [NWEndpoint], pinHex: String, reconnectName: String?) {
        guard let pin = Data(hexString: pinHex), pin.count == 32 else {
            status = .failed("Pin must be 64 hex characters.")
            return
        }
        guard !endpoints.isEmpty else {
            status = .failed("No address to connect to.")
            return
        }
        status = .connecting
        hostName = reconnectName
        sessionName = reconnectName
        sessionPinHex = pinHex
        connectedHostToSave = nil
        // A received file is a local artifact: it survives a disconnect (so the user can finish
        // sharing it) and is only cleared when a new session starts.
        receivedFile = nil
        task?.cancel()
        task = Task { [weak self] in await self?.run(endpoints: endpoints, pin: pin, reconnectName: reconnectName) }
    }

    func disconnect() {
        unbindConnection() // closes the transport (the inbound stream finishes) and drops the outbound lane
        task?.cancel()
        task = nil
        status = .idle
        hostName = nil
        connectedHostToSave = nil
        sessionName = nil
        sessionPinHex = nil
        incomingFiles.removeAll()
        displays = []
        activeDisplayID = 0
        hostLocked = false
        resetViewport()
        resetQualityDiagnostics()
        stopSessionMedia()
    }

    /// Session-media teardown: stop audio and drop the audio-anchored A/V presentation clock — which
    /// also releases any PTS-staged frames (decoded pixel buffers must not pool while idle). The next
    /// session's first audio frame re-anchors a fresh clock.
    private func stopSessionMedia() {
        audioPlayer.stop()
        renderer.presentationClock = nil
    }

    /// Re-target the live stream to another of the host's displays (no reconnect).
    func switchDisplay(to displayID: UInt32) {
        guard displayID != activeDisplayID,
              let display = displays.first(where: { $0.id == displayID }) else { return }
        activeDisplayID = displayID
        displaySize = CGSize(width: max(1, Double(display.width)), height: max(1, Double(display.height)))
        cursorNormalized = CGPoint(x: 0.5, y: 0.5)
        resetViewport()
        resetQualityDiagnostics()
        // New pump on the host = new sequence generation (its leading keyframe may itself drop).
        keyframeRecovery.reset()
        // Cut to the new display's window instead of easing across from the old one's.
        updateMagnifierTarget()
        renderer.snapWindow()
        send(.switchDisplay(SwitchDisplay(displayID: displayID)))
    }

    /// Ask the host to crop its capture to `crop` (padded, normalized) — the magnifier — but only when
    /// the visible `window` isn't already covered by the region the host is sending. Each re-crop makes
    /// the host call `SCStream.updateConfiguration`, which hiccups capture frame rate; re-cropping on
    /// every pan step collapsed zoomed content to ~4 fps. With hysteresis we re-crop only when the
    /// window nears the captured region's edge (you've panned into new territory) or the crop is too
    /// loose (e.g. just zoomed in) — so in-region panning keeps full fps while a move to a new region
    /// still re-crops promptly (the throttle's leading edge fires it immediately).
    func requestViewport(crop: CGRect, window: CGRect) {
        guard !isWindowCoveredByCurrentCrop(window) else { return }
        viewportRequests.request(crop)
    }

    /// Whether `window` (display-normalized) sits comfortably inside the region the host is already
    /// sending (`frameViewport`) AND that region isn't wastefully larger than the window — i.e. no
    /// re-crop is needed. A window edge that coincides with the display boundary needs no margin (the
    /// host can't capture past the screen).
    private func isWindowCoveredByCurrentCrop(_ window: CGRect) -> Bool {
        ViewportCoverage.windowCovered(window, by: frameViewport)
    }

    /// View-supplied magnifier inputs (the GeometryReader size + pinch zoom). Set by `LiveHUDView`;
    /// combined with the live cursor to compute the renderer's cursor-follow target window.
    var magnifierViewSize: CGSize = .zero { didSet { updateMagnifierTarget() } }
    var magnifierZoom: CGFloat = 1 { didSet { updateMagnifierTarget() } }

    /// Push the current cursor-follow target (display-normalized window) to the renderer, which eases
    /// toward it at display rate. Called whenever the cursor / zoom / view size changes. Full display
    /// (overview) when not zoomed or before the view size is known.
    private func updateMagnifierTarget() {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard magnifierZoom > 1.001, magnifierViewSize.width > 0, magnifierViewSize.height > 0 else {
            renderer.targetWindow = full
            return
        }
        renderer.targetWindow = ZoomGeometry(view: magnifierViewSize, displaySize: displaySize,
                                             cursor: cursorNormalized, zoom: magnifierZoom).visibleWindow
    }

    private func resetViewport() {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        frameViewport = full
        viewportRequests.reset()
    }

    private func resetQualityDiagnostics() {
        qualityTracker = QualityDiagnosticsTracker()
        qualityDiagnostics = QualityDiagnostics()
    }

    /// Report the 1s receive-side snapshot to the host (`ClientFeedback`, tag 29) so a host-side
    /// quality controller can adapt the stream, then refresh the RTT measurement with a fresh Ping
    /// on the same cadence. Piggybacks on the snapshot so feedback flows only while video does.
    private func sendQualityFeedback(_ snapshot: QualityDiagnostics) {
        send(.clientFeedback(ClientFeedback(
            receivedFPSX100: UInt32(max(0, (snapshot.receivedFPS * 100.0).rounded())),
            receivedMbpsX100: UInt32(max(0, (snapshot.receivedMbps * 100.0).rounded())),
            averageDecodeMsX100: UInt32(max(0, (snapshot.averageDecodeMs * 100.0).rounded())),
            decodeQueueDepth: 0,  // decode is inline + serial today; reserved for a pipelined decoder
            droppedFrames: UInt32(max(0, snapshot.droppedFrames)),
            rttMicros: latestRTTMicros
        )))
        send(.ping(Ping(sendMicros: UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000))))
    }

    // MARK: - Input (client → host)

    /// Control input is paused while the host screen is locked (injecting into the secure desktop is
    /// dropped by macOS anyway, and the lock overlay tells the user it's paused). Gates every input
    /// path here — not just the trackpad's hit-testing — so keyboard/scroll are paused too.
    private var inputPaused: Bool { hostLocked }

    func sendPointerMove(dx: CGFloat, dy: CGFloat) {
        guard !inputPaused else { return }
        let sentDx = dx.rounded()
        let sentDy = dy.rounded()
        send(.pointerMove(PointerMove(dx: Int32(sentDx), dy: Int32(sentDy))))
        // Predict the cursor locally for instant zoom-follow, using the exact delta we sent so
        // the prediction stays in lockstep with the host (its CursorPosition then matches, no snap).
        cursorNormalized = CursorPrediction(current: cursorNormalized, dx: sentDx, dy: sentDy,
                                            sensitivity: inputSensitivity, displaySize: displaySize).predicted
        updateMagnifierTarget()  // re-aim the eased cursor-follow window
    }

    func sendClick() {
        guard !inputPaused else { return }
        // Down then up on the ordered lane — FIFO guarantees they can't invert into a stuck click.
        send(.pointerButton(PointerButton(button: .left, isDown: true)))
        send(.pointerButton(PointerButton(button: .left, isDown: false)))
    }

    func sendScroll(dx: CGFloat, dy: CGFloat) {
        guard !inputPaused else { return }
        send(.scroll(Scroll(dx: Int32(dx.rounded()), dy: Int32(dy.rounded()))))
    }

    func sendText(_ text: String) {
        guard !inputPaused else { return }
        send(.typeText(TypeText(text: text)))
    }

    func sendKey(_ key: SpecialKey, modifiers: KeyModifiers = []) {
        guard !inputPaused else { return }
        send(.keyEvent(KeyEvent(special: key, modifiers: modifiers)))
    }

    /// Send a single character as a key chord (used for shortcuts like ⌘C).
    func sendChar(_ character: String, modifiers: KeyModifiers) {
        guard !inputPaused else { return }
        send(.keyEvent(KeyEvent(character: character, modifiers: modifiers)))
    }

    /// Push the iPhone's clipboard text to the Mac (user-initiated; iOS restricts auto-reads).
    func pasteToHost() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        // Cap outbound clipboard at the sender (same limit as the host): an over-cap payload would make
        // an oversized frame the host's decoder rejects (WireError.malformed), dropping the session.
        // Skip it entirely rather than truncate — half a clipboard is worse than none.
        guard Frame.shouldSendClipboard(text) else { return }
        send(.clipboardUpdate(ClipboardUpdate(text: text)))
    }

    /// Ask the host for a fresh keyframe so the video delta chain recovers after a gap. Called when the
    /// app returns to the foreground: while backgrounded VideoToolbox may have torn down the decode
    /// session, and frames missed during the gap leave the delta chain broken until the next keyframe.
    /// Routed through `KeyframeRecovery` so foreground, gap, and decode-failure triggers share ONE
    /// rate limiter — a foreground event racing a detected gap must not double-request.
    func requestKeyframe() {
        guard status == .streaming else { return }
        if keyframeRecovery.observeDiscontinuity(now: ProcessInfo.processInfo.systemUptime) {
            send(.requestKeyframe(RequestKeyframe()))
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

    /// Closes the bound connection's transport. Captured at bind (production = the session's
    /// `close()`); a settable seam so tests can assert teardown closes the connection — a concrete
    /// `PortviewClientSession` can't be constructed without a live socket.
    var closeConnection: (() -> Void)?

    /// Bind the ordered outbound input lane to a freshly-connected session.
    private func bindConnection(_ connection: PortviewClientSession) {
        self.connection = connection
        closeConnection = { connection.close() }
        outboundPump = OutboundInputPump(connection: connection)
    }

    /// Tear down the current connection — the single chokepoint (mirrors the SAS coordinator's
    /// `teardown`): CLOSE the
    /// transport first (cancels the NWConnection and finishes the inbound stream — a stream end,
    /// error, or reconnect drop must never leak a live connection), then drop the outbound lane.
    private func unbindConnection() {
        closeConnection?()
        closeConnection = nil
        outboundPump?.finish()
        outboundPump = nil
        connection = nil
    }

    private func send(_ message: AnyMessage) {
        // One ordered FIFO lane per connection → move/click/scroll/key keep their order on the wire.
        outboundPump?.enqueue(message)
    }

    // MARK: - Connect / stream / reconnect

    private enum SessionEnd { case streamed, notStreamed, hostError, evicted }

    private func run(endpoints: [NWEndpoint], pin: Data, reconnectName: String?) async {
        var connectedEndpoint: NWEndpoint?
        do {
            let (connection, endpoint) = try await connectFirst(endpoints, pin: pin)
            connectedEndpoint = endpoint
            bindConnection(connection)
            let end = try await streamSession(connection)
            unbindConnection()
            stopSessionMedia()
            switch end {
            case .hostError, .evicted:
                return // status already set (.failed / .idle); a host-initiated end is terminal
            case .notStreamed:
                if !hasFailed { status = .idle }
                return
            case .streamed:
                break // stream closed after a successful session — try to re-bind below
            }
        } catch {
            unbindConnection()
            stopSessionMedia()
            if Task.isCancelled { return }
            status = .failed("\(error)")
            return
        }

        guard let reconnectName, let connectedEndpoint, !Task.isCancelled else {
            if status == .streaming { status = .idle }
            return
        }
        await reconnectLoop(name: reconnectName, fallback: connectedEndpoint, pin: pin)
    }

    /// Try each candidate endpoint in order; return the first whose pinned QUIC handshake succeeds.
    /// Dials through a `PortviewTunnel` (one QUIC tunnel, primary stream opened on it) so a
    /// lane-capable host can later carry video/audio/stats on secondary streams; against an old
    /// host the tunnel's primary stream behaves exactly like today's bare connection.
    private func connectFirst(_ endpoints: [NWEndpoint], pin: Data) async throws -> (PortviewClientSession, NWEndpoint) {
        var lastError: Error?
        for endpoint in endpoints {
            if Task.isCancelled { throw CancellationError() }
            do {
                let connection = try await PortviewClientSession.connectQUIC(to: endpoint, pinnedCertificateSHA256: pin)
                return (connection, endpoint)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? PortviewClientError.noReachableEndpoint
    }

    /// Seed the pure reducer from the current @Published surface, fold `message` through it, and
    /// write back the fields that changed. Each write-back is guarded so an unchanged value doesn't
    /// fire `objectWillChange` — the reducer owns the semantic guards (the cursor's isClose epsilon,
    /// the frame-region change guard, the displaysUpdate retarget). Seeding per message (instead of
    /// keeping a long-lived reducer) keeps it in lockstep with out-of-band mutations like the local
    /// cursor prediction and a user-initiated `switchDisplay`.
    private func applyInbound(_ message: AnyMessage) {
        var state = InboundSessionReducer(
            isStreaming: status == .streaming,
            displays: displays,
            activeDisplayID: activeDisplayID,
            displaySize: displaySize,
            cursorNormalized: cursorNormalized,
            frameViewport: frameViewport,
            hostLocked: hostLocked)
        state.apply(message)
        if state.displays != displays { displays = state.displays }
        if state.activeDisplayID != activeDisplayID { activeDisplayID = state.activeDisplayID }
        if state.displaySize != displaySize { displaySize = state.displaySize }
        if state.cursorNormalized != cursorNormalized {
            cursorNormalized = state.cursorNormalized
            updateMagnifierTarget()  // re-aim the eased cursor-follow window
        }
        if state.frameViewport != frameViewport { frameViewport = state.frameViewport }
        if state.hostLocked != hostLocked { hostLocked = state.hostLocked }
        if state.isStreaming, status != .streaming { status = .streaming }
    }

    /// Run the handshake then the inbound loop for one connection. Returns when the connection
    /// closes (`.streamed`/`.notStreamed`) or the host reports a terminal error (`.hostError`).
    private func streamSession(_ connection: PortviewClientSession) async throws -> SessionEnd {
        // Fresh inbound-transfer slate per attempt (incl. each reconnect): release any orphaned
        // partial transfer from a dropped session and clear its stale "Receiving…" status.
        incomingFiles.removeAll()
        transferStatus = nil
        // Clear any stale lock overlay from a prior attempt; the host re-seeds the current state at
        // handshake (it only sends locked:true), so a reconnect after the host UNLOCKED can't strand it.
        hostLocked = false
        // A prior connection's RTT is meaningless for this one; 0 = "not yet measured".
        latestRTTMicros = 0
        // Fresh recovery generation: the host's video pump (and its sequence numbering) restarts
        // with the session, so cross-session contiguity is accidental.
        keyframeRecovery.reset()
        var client = ClientHandshake(
            deviceID: UIDevice.current.identifierForVendor?.uuidString ?? "ios-client",
            deviceName: UIDevice.current.name,
            supportedCodecs: [.hevc]
        )
        try await connection.send(.clientHello(client.start()))
        var didStream = false

        for await message in connection.inbound {
            switch message {
            case .serverHello(let hello):
                guard let display = hello.displays.first else { continue }
                let prefs = ClientSettings.load()
                let start = try client.handle(
                    hello, displayID: display.id,
                    maxWidth: display.width, maxHeight: display.height,
                    maxFPS: prefs.maxFPS, targetBitrate: prefs.targetBitrate
                )
                try await connection.send(.startSession(start))
                client.didStartStreaming()
                // Lane-capable host: the token on ServerHello (present iff its protocolVersion
                // >= ProtocolVersion.laneVersion) authorizes the three secondary lane streams
                // (video/audio/stats). Open them — any failure degrades silently back to
                // primary (the host has a bounded fallback). Old hosts carry no token, so
                // old-host sessions never attempt a lane open and behave exactly as today.
                if let sessionToken = hello.sessionToken {
                    connection.openLanes(sessionToken: sessionToken)
                }
                // Remember this host with the connection's RESOLVED concrete IP — this is what lets a
                // discovered (Bonjour `.service`) pairing persist, and a moved saved Mac refresh.
                if let (host, port) = ReconnectPlanning.hostPort(from: connection.resolvedRemoteEndpoint),
                   let pinHex = sessionPinHex {
                    connectedHostToSave = PairingPayload(host: host, port: port, pinHex: pinHex, name: sessionName ?? host)
                }
                applyInbound(message)  // folds displays/activeDisplayID/displaySize + status → .streaming
                didStream = true
            case .videoFrame(let frame):
                // Resync check BEFORE decode: a sequence gap means the depth-2 video lane
                // coalesced frames away and the delta chain is broken — every delta decode will
                // fail until the requested keyframe rebases it. The policy rate-limits, so this
                // also throttles the log line.
                if keyframeRecovery.observeArrival(sequence: frame.sequence, isKeyframe: frame.isKeyframe,
                                                   now: ProcessInfo.processInfo.systemUptime) {
                    logger.notice("video chain broken at seq=\(frame.sequence, privacy: .public) — requesting keyframe")
                    send(.requestKeyframe(RequestKeyframe()))
                }
                let decodeStart = ProcessInfo.processInfo.systemUptime
                var failedStage = "rebuild"
                let decoded: CVPixelBuffer?
                do {
                    let sample = try rebuild(frame)
                    failedStage = "decode"
                    decoded = try await decoder.decode(sample)
                } catch {
                    decoded = nil
                    if keyframeRecovery.observeDecodeFailure(now: ProcessInfo.processInfo.systemUptime) {
                        logger.notice("video \(failedStage, privacy: .public) failed seq=\(frame.sequence, privacy: .public) key=\(frame.isKeyframe, privacy: .public) (\(error, privacy: .public)) — requesting keyframe")
                        send(.requestKeyframe(RequestKeyframe()))
                    }
                }
                if let pixelBuffer = decoded {
                    let decodeMs = (ProcessInfo.processInfo.systemUptime - decodeStart) * 1_000.0
                    // The frame self-describes the region it shows; the reducer settles the residual
                    // zoom to it (atomic with the pixels — no separate echo to race), guarded so an
                    // unchanged region (steady state) doesn't fire `objectWillChange` ~60×/s. Applied
                    // only on a successful decode: a failed frame must not move the viewport.
                    let region = CGRect(x: frame.normalizedViewportX, y: frame.normalizedViewportY,
                                        width: frame.normalizedViewportW, height: frame.normalizedViewportH)
                    applyInbound(message)
                    // Hand the frame + its region + PTS to the renderer; the display-link `tick`
                    // draws the frame due at the shared presentation clock's time (or immediately
                    // while no audio has anchored the clock), easing the window toward the cursor
                    // target at display rate regardless of which frame is presented.
                    renderer.submit(pixelBuffer, region: region, ptsMicros: frame.ptsMicros)
                    if let snapshot = qualityTracker.recordDecodedFrame(frame, decodeMs: decodeMs) {
                        qualityDiagnostics = snapshot
                        sendQualityFeedback(snapshot)
                    }
                }
            case .cursorPosition:
                // A confirmation that matches the local prediction (the common case during a drag)
                // must not re-write `cursorNormalized`, or it re-targets the cursor-follow spring
                // every report for no visible motion → micro-stutter. The reducer owns that guard
                // (the isClose epsilon).
                applyInbound(message)
            case .displaysUpdate:
                // The host re-advertised its displays (a monitor connected/woke/was removed). The
                // reducer refreshes the list (so the display switcher reappears without a reconnect)
                // and — when the streamed display went away — retargets to the fallback with a reset
                // cursor/viewport.
                let previousActive = activeDisplayID
                applyInbound(message)
                if activeDisplayID != previousActive {
                    // Run the effects `switchDisplay` performs for a user-initiated switch: cut to
                    // the new display's window instead of easing across, and tell the host.
                    viewportRequests.reset()
                    resetQualityDiagnostics()
                    keyframeRecovery.reset()
                    updateMagnifierTarget()
                    renderer.snapWindow()
                    send(.switchDisplay(SwitchDisplay(displayID: activeDisplayID)))
                }
            case .hostLockStatus:
                // The host's screen locked/unlocked. Pause/resume the live view (a locked Mac captures
                // the secure desktop / blank, not the user's content). The reducer guards so an
                // unchanged state doesn't fire objectWillChange.
                applyInbound(message)
            case .clipboardUpdate(let update):
                UIPasteboard.general.string = update.text
            case .audioFrame(let audio):
                audioPlayer.play(sampleRate: Double(audio.sampleRate), channels: UInt32(audio.channels),
                                 ptsMicros: audio.ptsMicros, planarData: audio.data)
                // Mirror the audio-anchored clock into the video path (the first scheduled audio
                // frame anchors it) so both streams present against one timeline.
                if renderer.presentationClock != audioPlayer.presentationClock {
                    renderer.presentationClock = audioPlayer.presentationClock
                }
            case .viewport:
                // Defensive fallback: the host now embeds the region in every VideoFrame (see above),
                // so it no longer sends standalone `.viewport` echoes — but honor one if it arrives.
                applyInbound(message)
            case .qualityStats(let stats):
                qualityDiagnostics = qualityTracker.updateHostStats(stats)
            case .pong(let pong):
                // Both ends of the measurement are this device's monotonic clock (the host echoes
                // sendMicros verbatim). Guard against a garbage echo putting "sent" after "now".
                let nowMicros = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000)
                if nowMicros >= pong.sendMicros {
                    latestRTTMicros = UInt32(clamping: nowMicros - pong.sendMicros)
                }
            case .fileOffer(let offer):
                // The name is peer-supplied; offer() sanitizes it and opens the destination, or
                // rejects an unsafe name (path-traversal defense).
                if let name = incomingFiles.offer(offer) {
                    transferStatus = "Receiving \(name)…"
                } else {
                    transferStatus = "Rejected file with an unsafe name"
                }
            case .fileChunk(let chunk):
                if let file = incomingFiles.chunk(chunk) {
                    receivedFile = file
                    transferStatus = "Received \(file.name)"
                }
            case .bye:
                // Host ended the session deliberately (e.g. its Disconnect button) — a clean,
                // terminal close, NOT a drop, so don't attempt to re-bind.
                status = .idle
                return .evicted
            case .error(let error):
                status = .failed("Host error: \(error.message)")
                return .hostError
            default:
                break
            }
        }
        return didStream ? .streamed : .notStreamed
    }

    /// After a dropped session, keep re-binding the host (Bonjour-first) until it streams again or
    /// the reconnect window elapses. Input is paused (the UI shows the degraded state) until a
    /// candidate's pinned handshake succeeds and streaming resumes.
    private func reconnectLoop(name: String, fallback: NWEndpoint, pin: Data) async {
        var deadline = ProcessInfo.processInfo.systemUptime + Self.reconnectWindow
        while !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
            status = .reconnecting
            let discovered = await rediscover(name: name, timeout: Self.rediscoverTimeout)
            if Task.isCancelled { return }
            let candidates = ReconnectPlanning.reconnectCandidates(name: name, fallback: fallback, discovered: discovered)

            if let (connection, _) = try? await connectFirst(candidates, pin: pin) {
                bindConnection(connection)
                let end = (try? await streamSession(connection)) ?? .notStreamed
                unbindConnection()
                stopSessionMedia()
                if Task.isCancelled { return }
                switch end {
                case .hostError, .evicted:
                    return // terminal; status already set (.failed / .idle)
                case .streamed:
                    // Reconnected and streamed; if it drops again allow a fresh window.
                    deadline = ProcessInfo.processInfo.systemUptime + Self.reconnectWindow
                    continue
                case .notStreamed:
                    break // link came up but didn't stream — keep trying within the window
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
        if !Task.isCancelled, !hasFailed {
            status = .failed("Lost connection to \(name).")
        }
    }

    /// Browse Bonjour for up to `timeout`, returning as soon as a host named `name` appears (or the
    /// timeout elapses). Used to re-resolve a moved host's current address mid-session.
    private func rediscover(name: String, timeout: Duration) async -> [DiscoveredHost] {
        let browser = PortviewBrowser()
        browser.start()
        return await withTaskGroup(of: [DiscoveredHost]?.self) { group in
            group.addTask {
                for await hosts in browser.hosts where hosts.contains(where: { $0.name == name }) {
                    return hosts
                }
                return [] // stream finished without a match
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil // timeout sentinel
            }
            let first = await group.next() ?? nil
            browser.stop() // finish the stream so the browse task's `for await` ends
            group.cancelAll()
            for await _ in group {} // drain the now-finishing tasks
            return first ?? []
        }
    }

    private func rebuild(_ frame: VideoFrame) throws -> CMSampleBuffer {
        let encoded = try EncodedVideoSample(serialized: frame.data)
        return try VideoSampleSerializer.deserialize(encoded)
    }
}

private enum PortviewClientError: Error {
    case noReachableEndpoint
}

import Foundation
import Network
import UIKit
import CoreMedia
import PortviewProtocol
import PortviewTransport
import PortviewMedia

/// Drives a Portview client session: connect (cert-pinned) → handshake → receive video
/// frames → rebuild sample buffers → enqueue for display. If a live session drops, it re-binds the
/// host over Bonjour (surviving a LAN IP change) before giving up — the `.reconnecting` state.
@MainActor
final class SessionViewModel: ObservableObject {
    enum Status: Equatable {
        case idle, connecting, streaming, reconnecting, failed(String)
    }

    @Published var status: Status = .idle
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
    /// The name of the Mac this session is bound to (for reconnect status copy); nil before connect.
    @Published private(set) var hostName: String?
    /// Set when a stream succeeds: the host to remember, carrying the connection's resolved concrete
    /// IP (so discovered Macs persist and a moved saved Mac's IP refreshes). Nil otherwise.
    @Published private(set) var connectedHostToSave: PairingPayload?
    private var sessionName: String?
    private var sessionPinHex: String?
    private var qualityTracker = QualityDiagnosticsTracker()
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
    private var task: Task<Void, Never>?
    private var connection: PortviewConnection?
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

    /// Connect from a scanned QR pairing payload (host, port, and pin all included).
    func connect(payload: PairingPayload) {
        guard let nwPort = NWEndpoint.Port(rawValue: payload.port) else {
            status = .failed("Invalid port.")
            return
        }
        start(endpoints: [.hostPort(host: NWEndpoint.Host(payload.host), port: nwPort)],
              pinHex: payload.pinHex, reconnectName: payload.name ?? payload.host)
    }

    /// Reconnect a saved Mac, preferring its live Bonjour endpoint (survives a LAN IP change) and
    /// falling back to the saved host:port. The saved pin is unchanged, so cert pinning still
    /// gates the connection regardless of which candidate wins.
    func reconnect(saved: SavedHost, discovered: [DiscoveredHost]) {
        start(endpoints: saved.reconnectEndpoints(among: discovered),
              pinHex: saved.pinHex, reconnectName: saved.name)
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
        connection?.close() // close first so the inbound stream finishes, then drop the outbound lane
        unbindConnection()
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
        resetViewport()
        resetQualityDiagnostics()
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
        resetQualityDiagnostics()
        send(.switchDisplay(SwitchDisplay(displayID: displayID)))
    }

    /// Ask the host to crop its capture to `rect` (normalized) — the magnifier. Rate-limited by a
    /// leading+trailing throttle so the host crop tracks the cursor DURING a pan (the first move
    /// re-crops immediately, then at most once per interval) instead of only after movement stops.
    func requestViewport(_ rect: CGRect) {
        viewportRequests.request(rect)
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
        // Down then up on the ordered lane — FIFO guarantees they can't invert into a stuck click.
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

    /// Bind the ordered outbound input lane to a freshly-connected connection.
    private func bindConnection(_ connection: PortviewConnection) {
        self.connection = connection
        outboundPump = OutboundInputPump(connection: connection)
    }

    /// Tear down the current connection's outbound lane (so it never leaks across reconnects).
    private func unbindConnection() {
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
            audioPlayer.stop()
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
            audioPlayer.stop()
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
    private func connectFirst(_ endpoints: [NWEndpoint], pin: Data) async throws -> (PortviewConnection, NWEndpoint) {
        var lastError: Error?
        for endpoint in endpoints {
            if Task.isCancelled { throw CancellationError() }
            do {
                let connection = try await PortviewConnection.connectQUIC(to: endpoint, pinnedCertificateSHA256: pin)
                return (connection, endpoint)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? PortviewClientError.noReachableEndpoint
    }

    /// Run the handshake then the inbound loop for one connection. Returns when the connection
    /// closes (`.streamed`/`.notStreamed`) or the host reports a terminal error (`.hostError`).
    private func streamSession(_ connection: PortviewConnection) async throws -> SessionEnd {
        // Fresh inbound-transfer slate per attempt (incl. each reconnect): release any orphaned
        // partial transfer from a dropped session and clear its stale "Receiving…" status.
        incomingFiles.removeAll()
        transferStatus = nil
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
                displays = hello.displays
                activeDisplayID = display.id
                displaySize = CGSize(width: max(1, Double(display.width)), height: max(1, Double(display.height)))
                let prefs = ClientSettings.load()
                let start = try client.handle(
                    hello, displayID: display.id,
                    maxWidth: display.width, maxHeight: display.height,
                    maxFPS: prefs.maxFPS, targetBitrate: prefs.targetBitrate
                )
                try await connection.send(.startSession(start))
                client.didStartStreaming()
                // Remember this host with the connection's RESOLVED concrete IP — this is what lets a
                // discovered (Bonjour `.service`) pairing persist, and a moved saved Mac refresh.
                if let (host, port) = Self.hostPort(from: connection.resolvedRemoteEndpoint),
                   let pinHex = sessionPinHex {
                    connectedHostToSave = PairingPayload(host: host, port: port, pinHex: pinHex, name: sessionName ?? host)
                }
                status = .streaming
                didStream = true
            case .videoFrame(let frame):
                let decodeStart = ProcessInfo.processInfo.systemUptime
                if let sample = try? rebuild(frame),
                   let pixelBuffer = try? await decoder.decode(sample) {
                    let decodeMs = (ProcessInfo.processInfo.systemUptime - decodeStart) * 1_000.0
                    // The frame self-describes the region it shows; settle the residual zoom to it
                    // (atomic with the pixels — no separate echo to race). Guard the assignment so an
                    // unchanged region (steady state — the quantized value is bit-identical) doesn't
                    // fire `objectWillChange` ~60×/s.
                    let region = CGRect(x: frame.normalizedViewportX, y: frame.normalizedViewportY,
                                        width: frame.normalizedViewportW, height: frame.normalizedViewportH)
                    if region != frameViewport { frameViewport = region }
                    renderer.render(pixelBuffer)
                    if let snapshot = qualityTracker.recordDecodedFrame(frame, decodeMs: decodeMs) {
                        qualityDiagnostics = snapshot
                    }
                }
            case .cursorPosition(let cursor):
                // Guard like `frameViewport` above: a confirmation that matches the local prediction
                // (the common case during a drag) must not re-write `cursorNormalized`, or it re-targets
                // the cursor-follow spring every report for no visible motion → micro-stutter.
                let p = CGPoint(x: cursor.normalizedX, y: cursor.normalizedY)
                if !p.isClose(to: cursorNormalized) { cursorNormalized = p }
            case .clipboardUpdate(let update):
                UIPasteboard.general.string = update.text
            case .audioFrame(let audio):
                audioPlayer.play(sampleRate: Double(audio.sampleRate), channels: UInt32(audio.channels), planarData: audio.data)
            case .viewport(let v):
                // Defensive fallback: the host now embeds the region in every VideoFrame (see above),
                // so it no longer sends standalone `.viewport` echoes — but honor one if it arrives.
                let region = CGRect(x: v.normalizedX, y: v.normalizedY, width: v.normalizedW, height: v.normalizedH)
                if region != frameViewport { frameViewport = region }
            case .qualityStats(let stats):
                qualityDiagnostics = qualityTracker.updateHostStats(stats)
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
            let candidates = Self.reconnectCandidates(name: name, fallback: fallback, discovered: discovered)

            if let (connection, _) = try? await connectFirst(candidates, pin: pin) {
                bindConnection(connection)
                let end = (try? await streamSession(connection)) ?? .notStreamed
                unbindConnection()
                audioPlayer.stop()
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

    /// Reconnect candidates, ordered: a live Bonjour host matching by name (re-resolves the current
    /// IP after a LAN change) first, then the endpoint we were connected to as the fallback. Pure +
    /// `nonisolated` so it is unit-testable and callable off the main actor.
    /// Extract a concrete host:port from a connection's resolved endpoint (only `.hostPort` yields
    /// one — a `.service`/`.host`/nil endpoint returns nil). Pure + `nonisolated` for unit testing.
    nonisolated static func hostPort(from endpoint: NWEndpoint?) -> (host: String, port: UInt16)? {
        guard let endpoint, case let .hostPort(host, port) = endpoint else { return nil }
        let hostString: String
        switch host {
        case .ipv4(let address): hostString = "\(address)"
        case .ipv6(let address): hostString = "\(address)"
        case .name(let name, _): hostString = name
        @unknown default: hostString = "\(host)"
        }
        return (hostString, port.rawValue)
    }

    nonisolated static func reconnectCandidates(
        name: String, fallback: NWEndpoint, discovered: [DiscoveredHost]
    ) -> [NWEndpoint] {
        var endpoints: [NWEndpoint] = []
        if let match = discovered.first(where: { $0.name == name }) {
            endpoints.append(match.endpoint)
        }
        if !endpoints.contains(fallback) {
            endpoints.append(fallback)
        }
        return endpoints
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

extension CGPoint {
    /// Two normalized cursor positions are "the same" within sub-pixel epsilon. Used to skip a host
    /// cursor confirmation that already matches the local prediction: applying it would re-target the
    /// cursor-follow spring for no visible movement, so we drop it (the prediction already moved us).
    func isClose(to other: CGPoint, epsilon: CGFloat = 0.001) -> Bool {
        abs(x - other.x) < epsilon && abs(y - other.y) < epsilon
    }
}

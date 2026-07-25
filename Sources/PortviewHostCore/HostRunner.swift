// SPDX-License-Identifier: Apache-2.0
import Foundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreGraphics
import ApplicationServices
import PortviewProtocol
import PortviewTransport
import PortviewMedia
import os

private let logger = Logger(subsystem: "dev.finklea.portview", category: "host")

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
    /// An unknown-but-validly-signed key asked to enroll while the pairing window was open (han.3):
    /// surfaces ONLY the human-compare fingerprint, the claimed (sanitized) device name, the attempt
    /// id, and its deadline — NEVER the raw public key (key-material hygiene).
    case enrollmentRequest(attemptID: UUID, fingerprint: String, claimedName: String, expiresAt: Date)
    /// The enrollment ceremony for `attemptID` resolved — approved (enrolled) or not.
    case enrollmentResolved(attemptID: UUID, approved: Bool)
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

    /// `pairings` has NO default on purpose (Kimi K3 han.1 review): the gate and the (han.3)
    /// enrollment ceremony must share ONE PairingStore instance — a second instance's cache goes
    /// stale on the first's writes. Forcing the caller to construct it keeps that authority split
    /// impossible to reach by omitting an argument.
    public func events(identity: HostPermissionIdentity, control: HostControl? = nil,
                       sasControl: SASPairingControl? = nil,
                       authPolicy: MutualAuthPolicy = .required,
                       pairings: PairingStore,
                       enrollment: EnrollmentAuthority? = nil) -> AsyncStream<HostRunnerEvent> {
        AsyncStream { continuation in
            let task = Task {
                await run(identity: identity, control: control, sasControl: sasControl,
                          authPolicy: authPolicy, pairings: pairings, enrollment: enrollment) { event in
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
        authPolicy: MutualAuthPolicy = .required,
        pairings: PairingStore,
        enrollment: EnrollmentAuthority? = nil,
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
            // Fail CLOSED if the cert hash is unavailable (spec §4-RESOLVED must-fix): the hash is
            // the SAS commit binding AND the signed-challenge relay defense — hosting without it
            // would silently drop both. (Was a degrade-to-`[]` fallback.)
            let hostCertBytes = [UInt8](try tlsIdentity.certificateSHA256())
            if case .legacyBootstrap = authPolicy {
                onEvent(.message("⚠️ Device authentication is in legacy-bootstrap mode: clients that predate device identity are admitted un-authenticated. Enrolling a first device tightens the gate automatically."))
            }
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
                                             authPolicy: authPolicy, pairings: pairings,
                                             emit: onEvent, control: control, sas: sasControl,
                                             enrollment: enrollment)
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
    ///
    /// Multiplexed (grouped) delivery is enabled for QUIC lane-splitting: every inbound tunnel
    /// arrives as a connection group whose streams classify by first byte — legacy bare dials
    /// arrive as single-stream groups and flow down the existing frame/serve path unchanged
    /// (transport-verified by `LaneTransportTests`).
    static func startListener(
        identity: TLSIdentity,
        serviceName: String,
        preferredPort: UInt16?
    ) async throws -> (listener: PortviewListener, port: UInt16) {
        if let preferredPort {
            do {
                let listener = try PortviewListener(quicIdentity: identity, serviceName: serviceName, port: preferredPort,
                                                    multiplexed: true)
                do {
                    let port = try await listener.start()
                    return (listener, port.rawValue)
                } catch {
                    listener.cancel()  // release the partially-started listener before falling back
                    throw error
                }
            } catch {
                logger.warning("Preferred port \(preferredPort, privacy: .public) unavailable (\(error, privacy: .public)); using an OS-assigned port.")
            }
        }
        let listener = try PortviewListener(quicIdentity: identity, serviceName: serviceName, multiplexed: true)
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

    /// Owns a connection's inbound iterator for the connection's LIFETIME and funnels every read
    /// through at most one in-flight read task. `AsyncStream.next()` isn't cancellation-aware, so a
    /// deadline race can't cancel a read that hasn't yielded; instead of abandoning the loser (and
    /// copying the iterator back to the caller while that read may still be mutating it — a data
    /// race), a timed-out read stays PENDING here and the next call awaits that same read. The
    /// iterator is never copied in or out, so no caller can race it, and a message that arrives
    /// after a timeout is delivered to the next read rather than dropped by a leaked task.
    ///
    /// `@unchecked Sendable` asserts: `iterator` is touched only from inside the single pending
    /// read task; `pendingRead` creation/clearing is lock-serialized, and a new read task starts
    /// only after the previous one's `iterator.next()` has settled (its value was delivered), so
    /// iterator accesses never overlap. Callers must read sequentially (one serve loop per
    /// connection), matching how `serveSession`/`serveSASPreamble` consume inbound messages.
    final class MessageReader: @unchecked Sendable {
        private var iterator: AsyncStream<AnyMessage>.AsyncIterator
        private let lock = NSLock()
        private var pendingRead: Task<AnyMessage?, Never>?

        init(_ stream: AsyncStream<AnyMessage>) {
            iterator = stream.makeAsyncIterator()
        }

        /// The single in-flight read, starting one only if none is pending. A read left pending by
        /// a timed-out `next(deadline:)` is reused (its result is memoized by the `Task`), so a
        /// late message goes to the next reader instead of an abandoned background task.
        private func pendingOrStartRead() -> Task<AnyMessage?, Never> {
            lock.lock(); defer { lock.unlock() }
            if let pendingRead { return pendingRead }
            let read = Task { [self] in await iterator.next() }
            pendingRead = read
            return read
        }

        /// Clear `read` once its value has actually been delivered to a caller, so the next call
        /// starts a fresh read. A timed-out read is deliberately NOT cleared — it stays pending.
        private func finish(_ read: Task<AnyMessage?, Never>) {
            lock.lock(); defer { lock.unlock() }
            if pendingRead == read { pendingRead = nil }
        }

        /// Next inbound message; `nil` when the stream ends. Blocks until one arrives.
        func next() async -> AnyMessage? {
            let read = pendingOrStartRead()
            let message = await read.value
            finish(read)
            return message
        }

        /// Race the next inbound message against `deadline`, returning `nil` on timeout instead of
        /// blocking indefinitely. Used to bound serve paths' first-message read, which previously
        /// had no application-level deadline (only the ~30s QUIC idle timeout), letting an
        /// idle/phantom connection hold a serve-cap slot for the full ~30s. On timeout the read
        /// stays pending (see above); it is not lost.
        func next(deadline: Duration) async -> AnyMessage? {
            let read = pendingOrStartRead()
            let gate = SingleResumeGate()
            return await withCheckedContinuation { (continuation: CheckedContinuation<AnyMessage?, Never>) in
                Task {
                    let message = await read.value
                    if await gate.tryResume() {
                        finish(read)
                        continuation.resume(returning: message)
                    }
                }
                Task {
                    try? await Task.sleep(for: deadline)
                    if await gate.tryResume() { continuation.resume(returning: nil) }
                }
            }
        }
    }

    /// Holds the latest `ClientFeedback` snapshot (tag 29) a connection's client reported, read by
    /// the video pump's `AdaptiveRateController` on each stats interval. Lock-guarded (mirroring
    /// `HostControl`) so the inbound dispatch task can write while the encode path reads.
    final class ClientFeedbackHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var latestValue: ClientFeedback?

        func update(_ feedback: ClientFeedback) {
            lock.lock()
            latestValue = feedback
            lock.unlock()
        }

        func latest() -> ClientFeedback? {
            lock.lock()
            defer { lock.unlock() }
            return latestValue
        }
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
        authPolicy: MutualAuthPolicy,
        pairings: PairingStore,
        emit: @escaping @Sendable (HostRunnerEvent) -> Void = { _ in },
        control: HostControl? = nil,
        sas: SASPairingControl? = nil,
        enrollment: EnrollmentAuthority? = nil
    ) async {
        await withTaskCancellationHandler {
            await serveSession(connection, registry: registry, hostCertSHA256: hostCertSHA256,
                               authPolicy: authPolicy, pairings: pairings,
                               emit: emit, control: control, sas: sas, enrollment: enrollment)
        } onCancel: {
            connection.close()
        }
    }

    /// `internal` (not `private`) so the auth-gate loopback integration tests can drive it
    /// directly (same precedent as `serveSASPreamble`). The two trailing closures are test seams:
    /// `onAuthGateOutcome` observes the gate's decision, `didBuildScaffolding` fires exactly where
    /// session scaffolding construction begins — a rejected peer must never reach it.
    static func serveSession(
        _ connection: PortviewConnection,
        registry: DisplayRegistry,
        hostCertSHA256: [UInt8] = [],
        authPolicy: MutualAuthPolicy,
        pairings: PairingStore,
        emit: @escaping @Sendable (HostRunnerEvent) -> Void = { _ in },
        control: HostControl? = nil,
        sas: SASPairingControl? = nil,
        enrollment: EnrollmentAuthority? = nil,
        onAuthGateOutcome: (@Sendable (AuthGateOutcome) -> Void)? = nil,
        didBuildScaffolding: (@Sendable () -> Void)? = nil
    ) async {
        // Peek the first message to LOCK this connection's role BEFORE building any session
        // scaffolding. An SAS-preamble connection (first message = client commit) is UNPINNED (TOFU)
        // and must never reach the clipboard / input-injector / capture / file path — trust is decided
        // by the SAS code comparison, after which the client re-dials pinned. (v2 review CRITICAL-3.)
        // Bounded by a short deadline (not just the ~30s QUIC idle timeout): an idle or
        // double-delivered "phantom" connection would otherwise hold a serve-cap slot for the full
        // ~30s, starving a legit client.
        let inbound = MessageReader(connection.inbound)
        guard let firstMessage = await inbound.next(deadline: .seconds(5)) else {
            connection.close(); return
        }
        if case .sasClientCommit(let commit) = firstMessage {
            await serveSASPreamble(connection, clientCommit: commit, inbound: inbound,
                                   hostCertSHA256: hostCertSHA256, sas: sas, emit: emit)
            return
        }

        // The first frame must be exactly SASClientCommit or ClientHello (spec §4-RESOLVED, §3
        // corrections); any other opener is a protocol violation and closes before a challenge is
        // even issued.
        guard case .clientHello(let hello) = firstMessage else { connection.close(); return }
        // Sanitized ONCE here (must-fix 4) and reused everywhere the name flows from this point on:
        // the enrollment-ceremony event, the persisted `enroll`, and `.deviceConnected` below — never
        // re-derived from the raw wire value again.
        let sanitizedDeviceName = DeviceNameSanitizer.sanitize(hello.deviceName)

        // Mutual-auth gate (spec §3): challenge/verify BEFORE any scaffolding — and before the
        // display guard below, because authorization is a connection-level decision that must not
        // depend on a display being attached. The policy is HOST-LOCAL, never wire-negotiated.
        // Entry-level snapshot, used ONLY for the eviction sweep below — evicting on entry is fine
        // (Finding A review). The gate's own admission DECISION must never trust this snapshot: see
        // `effectiveMode` passed to `serveAuthGate`.
        let entryMode = authPolicy.effectiveMode(now: Date(), enrollment: await pairings.enrollmentSnapshot())
        // If the policy has tightened to `.required` (a device enrolled, the window expired, or the
        // store is unreadable → fail closed), terminate any sessions still lingering from the
        // bootstrap era before doing anything else. This lazy sweep fires on the next connection;
        // the EAGER sweep at the instant of enrollment is han.3's enroll-ceremony hook.
        if entryMode == .required { control?.evictLegacyAdmitted() }
        let outcome = await serveAuthGate(
            inbound: inbound, hostCertSHA256: hostCertSHA256,
            effectiveMode: { authPolicy.effectiveMode(now: Date(), enrollment: await pairings.enrollmentSnapshot()) },
            isSASWindowOpen: { await sas?.isOpen() ?? false },
            pairings: pairings,
            // Bound to the live registry's fence/generation (design §3). No `control` (the CLI's
            // current default) means no registry exists to fence against, so admit unconditionally
            // at generation 0 — same as today's un-fenced behavior; `HostRunner.run` minting a
            // process-local `HostControl` for the `nil` case is a separate, not-yet-landed item.
            admissionTicket: { keyID in control?.admissionTicket(for: keyID) ?? AdmissionTicket(keyID: keyID, generation: 0) },
            sendChallenge: { try await connection.send(.serverChallenge($0)) })
        onAuthGateOutcome?(outcome)
        switch outcome {
        case .rejected(let reason):
            logger.notice("auth gate rejected connection: \(String(describing: reason), privacy: .public)")
            connection.close()
            return
        case .unknownKey(let publicKey):
            // han.3 enrollment ceremony (spec §4-RESOLVED must-fix 1): a validly-signed but
            // unenrolled key gets ONE chance to enroll, gated on an open pairing window. Log ONLY
            // the fingerprint in either outcome — never the raw key bytes (key-material hygiene).
            let enrolled = await runEnrollmentCeremony(
                publicKey: publicKey, deviceName: sanitizedDeviceName, connection: connection,
                enrollment: enrollment, sas: sas, control: control, pairings: pairings, emit: emit)
            guard enrolled else {
                logger.notice("auth gate: unknown key not enrolled (fingerprint \(KeyFingerprint.short(forPublicKey: Data(publicKey)), privacy: .public))")
                connection.close()
                return
            }
            logger.info("auth gate: unknown key enrolled (fingerprint \(KeyFingerprint.short(forPublicKey: Data(publicKey)), privacy: .public))")
        case .legacyAdmitted:
            emit(.message("⚠️ Legacy client connected without device authentication (bootstrap policy — enroll this device to tighten)."))
        case .authenticated(let deviceID, _):
            // MINIMAL han.4 Task-7 compile-fix: the gate now carries the admission ticket captured
            // at authorization (Order-A), but `control?.register` further down still uses its own
            // Task-4 placeholder ticket — threading THIS ticket into register for real (plus the
            // durable + post-await recheck) is Task 8's job (design §5).
            logger.info("auth gate: authenticated device \(deviceID, privacy: .public)")
        }
        // The session's auth class is carried into `control.register` so a later policy tightening
        // can evict exactly the legacy-admitted sessions (HostControl.evictLegacyAdmitted).
        let sessionAuthClass: HostControl.SessionAuthClass =
            outcome == .legacyAdmitted ? .legacyAdmitted : .authenticated

        guard let firstDisplay = await registry.current().first else { connection.close(); return }
        didBuildScaffolding?()

        // MINIMAL han.4 Task-6 compile-fix: OutboundLane/HostLaneRouter/pumpVideo now require a
        // SessionCapability (design §2/§4 finding 4/H-e — each gates its post-encode send / sink
        // on it). This is a THIRD standalone placeholder, distinct from `inboundEffectCapability`
        // below and the ticket capability minted inline at `control.register` further down —
        // nothing in THIS function invalidates any of the three yet. Unifying all three into ONE
        // real per-session capability, invalidated Invalidate-First in this defer, is Task 8's job
        // (see the report for the exact seam).
        let outboundEffectCapability = SessionCapability()
        // One ordered outbound lane for this whole connection (survives display switches), owned
        // here and finished in the teardown defer: clipboard pushes, cursor confirmations, and
        // HostControl broadcast/file sends all enqueue onto it, so no fire-and-forget send can
        // reorder under load or outlive the session.
        let outbound = OutboundLane(connection: connection, capability: outboundEffectCapability)
        // The token minter runs only for a lane-capable handshake (negotiated >= laneVersion) —
        // an old client never gets a token minted or advertised (ServerHandshake stamps the
        // negotiated version, and ServerHello carries the token iff that stamp >= laneVersion).
        var server = ServerHandshake(displays: Self.displayInfos(from: await registry.current()), supportedCodecs: [.hevc],
                                     mintSessionToken: LaneSessionToken.mint)
        // Lane routing (QUIC lane-splitting, w6n.4): pumpVideo's video/audio/stats sends route
        // onto the client's secondary lane streams once it binds them; legacy sessions — and any
        // lane that dies or never opens — flow on primary. See HostLaneRouter for the
        // flip/fallback rules. Video keeps its back-pressured direct drain through the router;
        // it never rides the session's OutboundLane.
        let router = HostLaneRouter(primary: connection, capability: outboundEffectCapability)
        var laneBindTask: Task<Void, Never>?
        // MINIMAL han.4 Task-5 compile-fix: ClipboardSync/FileReceiver/InputInjector now require a
        // SessionCapability (design §2/§4 — each gates its irreducible effect boundary on it).
        // Nothing in THIS function invalidates this placeholder yet; the real per-session
        // capability (shared with `register`'s ticket/capability above, invalidated
        // Invalidate-First on every teardown path) is Task 8's serve-loop reorder.
        let inboundEffectCapability = SessionCapability()
        let clipboard = ClipboardSync(capability: inboundEffectCapability)
        clipboard.start { text in
            // Cap outbound clipboard at the sender: an over-cap copy would make an oversized frame the
            // client's decoder rejects (WireError.malformed), dropping the session. Skip it entirely
            // (never truncate — half a clipboard is worse than none).
            guard Frame.shouldSendClipboard(text) else {
                logger.notice("clipboard: skipping \(text.utf8.count, privacy: .public)-byte copy over \(Frame.maxClipboardBytes, privacy: .public)-byte cap")
                return
            }
            outbound.enqueue(.clipboardUpdate(ClipboardUpdate(text: text)))
        }
        let fileReceiver = FileReceiver(capability: inboundEffectCapability)
        // Latest client-reported receive-side quality snapshot for THIS connection, read by the
        // video pump's adaptive rate controller each stats interval.
        let clientFeedback = ClientFeedbackHolder()
        // Identifies this session for the host UI; set once the client handshake names the device.
        var connectedDeviceID: String?
        // Client-requested stream params (StartSession), honored by capture + encoder and reused
        // when the display is switched mid-session.
        var requestedFPS = 60
        var requestedBitrate: Int?

        // Injector, capture engine, and video pump are (re)bound to the active display; switching
        // re-targets all three. `currentCapture` lets viewport (magnifier) requests re-crop the
        // live stream. All of these are touched only from this inbound loop's task.
        // Cursor reports ride the session's shared outbound lane (coalescing, last-wins), so
        // confirmations can't reorder/back-step the client's cursor-follow.
        let cursorPump = CursorReportPump(lane: outbound)
        var injector = makeInjector(for: firstDisplay, cursorPump: cursorPump, capability: inboundEffectCapability)
        var currentCapture: CaptureEngine?
        var videoTask: Task<Void, Never>?
        defer {
            clipboard.stop()
            fileReceiver.cancelAll()
            videoTask?.cancel()
            // Stops consuming the accepted-lane stream, which revokes the token's authorization
            // at the tunnel — a dead session's token can't bind new lanes.
            laneBindTask?.cancel()
            // MINIMAL han.4 Task-6 wiring: terminalize the router so a late bind racing teardown
            // is refused and every bound secondary-lane stream closes promptly (design §2/§4
            // finding 4/H-e). Full Invalidate-First reordering (capability.invalidate() as this
            // defer's FIRST statement, ahead of every cancel/close) is Task 8's job.
            router.closeBoundLanes()
            currentCapture?.stop()
            outbound.finish()
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
            injector = makeInjector(for: display, cursorPump: cursorPump, capability: inboundEffectCapability)
            let capture = CaptureEngine(width: display.width, height: display.height)
            currentCapture = capture
            // A lane-death flip forces its keyframe through THIS capture's request path (the same
            // consumeKeyframeRequest plumbing a client `.requestKeyframe` uses); re-pointed on
            // every display switch so the request always reaches the live capture.
            router.setKeyframeRequester { await capture.requestKeyframe() }
            let fps = requestedFPS
            let bitrate = requestedBitrate
            videoTask = Task { await pumpVideo(router, display: display, capture: capture, fps: fps, bitrate: bitrate, feedback: clientFeedback, capability: outboundEffectCapability, emit: emit) }
            logger.info("Streaming display \(display.displayID, privacy: .public) source \(display.width, privacy: .public)x\(display.height, privacy: .public).")
        }

        var pendingMessage: AnyMessage? = firstMessage
        while let message = pendingMessage {
            switch message {
            case .clientHello(let hello):
                do {
                    let reply = try server.handle(hello)
                    // Authorize secondary lane streams BEFORE the token-carrying ServerHello goes
                    // out, so a well-behaved client can't race its lane opens past authorization.
                    // HARD invariant (w6n.3 review): acceptLanes runs at most ONCE per primary
                    // connection — re-authorizing on a repeat ClientHello would REPLACE the
                    // token's authorization and reset its duplicate-lane protection.
                    // `authorizeLanesOnce` refuses every call after the first, regardless of how
                    // many hellos arrive; an old-version session mints no token and never enters
                    // this branch.
                    if let token = server.sessionToken,
                       let lanes = router.authorizeLanesOnce({ connection.acceptLanes(sessionToken: token) }) {
                        laneBindTask = Task {
                            for await accepted in lanes {
                                router.bind(accepted.lane, accepted.connection)
                            }
                        }
                    }
                    try await connection.send(.serverHello(reply))
                    if connectedDeviceID == nil {
                        // Identify the session per-connection (not by the device's stable id): on a
                        // reconnect the old session's disconnect must not evict the new one's entry.
                        let sessionID = UUID().uuidString
                        connectedDeviceID = sessionID
                        // MINIMAL han.4 Task-4 compile-fix: the register signature now requires a
                        // ticket + capability. The real admission wiring (ticket captured at
                        // authorization, capability threaded through every effect boundary, the
                        // post-await recheck) is Task 8; until then this constructs a fresh capability
                        // and a legacy/nil-keyID ticket so the call compiles and behaves as today
                        // (legacy tickets skip the fence/generation check).
                        control?.register(sessionID, connection, outbound: outbound, authClass: sessionAuthClass,
                                          ticket: AdmissionTicket(keyID: nil, generation: 0),
                                          capability: SessionCapability())
                        emit(.deviceConnected(id: sessionID, name: sanitizedDeviceName))
                        // Seed this client with the current lock state (the live broadcast only reaches
                        // already-connected clients), so one that connects while locked pauses at once.
                        if LockMonitor.currentlyLocked() {
                            try? await connection.send(.hostLockStatus(HostLockStatus(locked: true)))
                        }
                    }
                } catch {
                    logger.error("handshake error: \(error, privacy: .public)")
                    videoTask?.cancel()
                    return
                }
            case .startSession(let start):
                do { try server.handle(start) } catch { logger.error("startSession error: \(error, privacy: .public)"); return }
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
            case .clientFeedback(let feedback):
                clientFeedback.update(feedback)
                logger.notice("client feedback fps=\(feedback.receivedFPS, privacy: .public) mbps=\(feedback.receivedMbps, privacy: .public) decodeMs=\(feedback.averageDecodeMs, privacy: .public) dropped=\(feedback.droppedFrames, privacy: .public)")
            case .requestKeyframe:
                // Client asked for a fresh keyframe (e.g. it just returned to the foreground and its
                // delta chain has a gap). Force the next encoded frame to a keyframe on the active
                // capture so the stream recovers without waiting for the periodic keyframe.
                await currentCapture?.requestKeyframe()
            default:
                break
            }
            pendingMessage = await inbound.next()
        }
        logger.notice("session inbound drained — serve loop exiting")
    }

    /// The mutual-auth gate's decision for one streaming connection.
    enum AuthGateOutcome: Equatable, Sendable {
        /// The peer proved possession of an enrolled key; `deviceID` = SHA256(pubkey) hex. `ticket`
        /// is the admission ticket captured at authorization (design §3, Order-A) — its generation
        /// reflects the instant of THIS authorization, never the later `register` instant.
        case authenticated(deviceID: String, ticket: AdmissionTicket)
        /// The peer never answered the challenge and the ACTIVE policy is legacy bootstrap.
        case legacyAdmitted
        /// A validly-signed key that isn't enrolled — the han.3 enrollment-ceremony hook (spec
        /// §4-RESOLVED must-fix 1). `publicKey` is the exact snapshot the caller may offer for
        /// enrollment; until the ceremony is wired (Task 6), the caller closes on this outcome.
        case unknownKey(publicKey: [UInt8])
        /// Fail closed: the caller must close the connection with no scaffolding built.
        case rejected(AuthGateRejection)
    }

    enum AuthGateRejection: Equatable, Sendable {
        case missingHostCertHash, sendFailed, timeout, unexpectedMessage, invalidSignature
        /// The key is fenced (mid-revoke, design §4/H-c): the `admissionTicket` seam returned `nil`
        /// for it. Rejected here even for a valid signature over a still-enrolled key — Order-A
        /// (design §3): the fence must win over a durable record that hasn't caught up yet.
        case revoking
    }

    /// How long the gate waits for `ClientAuth` after issuing its challenge. Long enough for a
    /// relayed/Tailscale RTT + a client keychain read; under an active bootstrap policy it is also
    /// the legacy client's admittance delay (a pre-auth client skips the unknown challenge tag and
    /// never replies), so it stays low.
    static let authGateDeadline: Duration = .seconds(3)

    /// Run the signed-challenge auth gate (spec §3 + §4-RESOLVED) BEFORE any session scaffolding:
    /// issue a fresh 32-byte CSPRNG nonce, read exactly ONE message under a single `deadline`, and
    /// require BOTH a valid signature over the frozen payload (nonce ‖ host-cert-hash — replay +
    /// relay defenses) AND an enrolled exact-match key. Everything else fails closed, except a
    /// SILENT peer under `.bootstrap` with NO pairing window open, admitted as a warned legacy
    /// session. `isSASWindowOpen` is the legacy barrier (design v2 H3): while a ceremony window is
    /// open, a silent peer under `.bootstrap` is rejected (`.timeout`) rather than legacy-admitted —
    /// a legacy peer could otherwise watch the host screen and click Deny on someone else's
    /// enrollment prompt. It is a closure evaluated AT the timeout decision point, not sampled once
    /// at gate entry (review TOCTOU fix): a silent peer already in-flight when the user opens the
    /// pairing window must still be caught by the barrier, even though the window wasn't open yet
    /// when the gate started waiting — the window-open evict sweep can't catch it, since the
    /// admission would only register after the sweep runs. `effectiveMode` gets the SAME
    /// decision-time treatment (Finding A, adversarial review CRITICAL): the ACTIVE policy mode is
    /// evaluated at the timeout decision, never sampled once before the wait — a peer that holds a
    /// silent connection through the whole wait while a first enrollment promotes the store from
    /// `.bootstrap` to `.required` must be rejected against the CURRENT mode, not legacy-admitted
    /// against a now-stale `.bootstrap` snapshot (and a now-closed window). Exactly one read (Sol
    /// han.1 review): the initial ClientHello was already consumed before this gate, so any further
    /// message that isn't ClientAuth is a violation — granting a stray/duplicate frame a fresh
    /// deadline would let paced duplicates starve the connection slots. The outbound side is a
    /// closure seam (the caller binds it to `connection.send`) so the gate's decision logic is
    /// testable without sockets.
    static func serveAuthGate(
        inbound: MessageReader,
        hostCertSHA256: [UInt8],
        effectiveMode: @Sendable () async -> MutualAuthPolicy.Mode,
        isSASWindowOpen: @Sendable () async -> Bool,
        pairings: PairingStore,
        // Reservation seam (design §2/§3, Order-A): captures the admission ticket AT
        // authorization — immediately after signature verify, before the durable `authorizedClient`
        // lookup — so the ticket's generation reflects this instant, never the later `register`
        // instant (finding 1). Bound in production to `control.admissionTicket`; `nil` means the key
        // is fenced (mid-revoke).
        admissionTicket: @Sendable (ClientKeyID) -> AdmissionTicket?,
        deadline: Duration = authGateDeadline,
        sendChallenge: @Sendable (ServerChallenge) async throws -> Void
    ) async -> AuthGateOutcome {
        // Spec must-fix: auth binding fails closed when the 32-byte host cert hash is unavailable —
        // challenging without it would sign away the relay-defense field. (Production can't reach
        // this: `run` aborts hosting if the hash can't be computed.)
        guard hostCertSHA256.count == 32 else { return .rejected(.missingHostCertHash) }
        var rng = SystemRandomNumberGenerator()
        let nonce = (0..<ServerChallenge.nonceLength).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        do { try await sendChallenge(ServerChallenge(nonce: nonce)) } catch {
            return .rejected(.sendFailed)
        }
        guard let message = await inbound.next(deadline: deadline) else {
            // Silence: a pre-auth legacy client skips the unknown challenge tag and never replies.
            // Read the ACTIVE mode HERE, at the decision point, not before the wait (Finding A) — a
            // policy that tightens to `.required` mid-wait must still catch this peer.
            let mode = await effectiveMode()
            // Legacy barrier: no legacy admissions while the ceremony window is open. Read HERE, at
            // the decision point, not before the wait — a window opened mid-wait must still trip it.
            guard mode == .bootstrap else { return .rejected(.timeout) }
            return await isSASWindowOpen() ? .rejected(.timeout) : .legacyAdmitted
        }
        guard case .clientAuth(let auth) = message else {
            // Anything that isn't the expected auth (a stray/duplicate hello or any other frame) is
            // a protocol violation in BOTH modes — a peer that SPEAKS non-auth is not a silent
            // legacy client, and it gets no second read.
            return .rejected(.unexpectedMessage)
        }
        guard ClientAuthCrypto.verify(publicKey: auth.publicKey, signature: auth.signature,
                                      nonce: nonce, hostCertSHA256: hostCertSHA256) else {
            return .rejected(.invalidSignature)
        }
        // Order-A (design §3): capture the ticket HERE — immediately after signature verify,
        // BEFORE the durable `authorizedClient` lookup below — so its generation reflects THIS
        // authorization instant. A ticket stamped at register (after enrollment ceremony,
        // scaffolding, ServerHello) would read a generation that already absorbed a revoke+re-enroll
        // that happened in between, defeating the whole point of finding 1. `nil` = fenced
        // (mid-revoke): reject before the durable lookup even runs.
        let keyID = PairingStore.deviceID(forPublicKey: Data(auth.publicKey))
        guard let ticket = admissionTicket(keyID) else { return .rejected(.revoking) }
        guard let record = await pairings.authorizedClient(forPublicKey: Data(auth.publicKey)) else {
            // han.3 hook: unknown key + VALID signature becomes the enrollment-ceremony snapshot
            // (spec §4-RESOLVED must-fix 1). The caller (`serveSession`) hands this to
            // `runEnrollmentCeremony`, which is the ONLY path by which a new device enrolls.
            return .unknownKey(publicKey: auth.publicKey)
        }
        try? await pairings.touch(id: record.id)  // lastSeen is best-effort
        return .authenticated(deviceID: record.id, ticket: ticket)
    }

    /// Runs the han.3 enrollment ceremony for an `.unknownKey` gate outcome (spec §4-RESOLVED
    /// must-fix 1): the gate has already verified the signature, so this is the sole path by which
    /// a new device becomes enrolled. Returns `true` iff the connection should proceed into the
    /// streaming loop as `.authenticated`; `false` means the caller must close with no further
    /// action — every applicable `HostRunnerEvent` has already been emitted before returning.
    ///
    /// No wire messages are sent here: the client just waits on the still-open connection for a
    /// ServerHello or a close. The pending/resolved state is host-local UI only, surfaced via
    /// `emit` (never a wire message, and never the raw key — only its fingerprint).
    ///
    /// Requires ALL of `enrollment`, an OPEN pairing window (`sas?.isOpen()`), and `control`
    /// (eviction needs it) to even attempt the ceremony — any missing dependency closes with no
    /// ceremony, matching the pre-Task-6 `.unknownKey` behavior exactly. Deliberately does NOT wrap
    /// `awaitDecision` in any extra cancellation machinery: `serve`'s `withTaskCancellationHandler`
    /// only fires on whole-group teardown (host shutdown, listener cancel) — a peer that dies
    /// mid-prompt is NOT detected while `awaitDecision` parks. That individual connection is
    /// cleaned up only by `EnrollmentAuthority`'s own 25 s deadline (accepted design cost), which
    /// resolves `false` without blocking the source; a second cancellation path here would only
    /// race the deadline or the group-teardown case.
    private static func runEnrollmentCeremony(
        publicKey: [UInt8],
        deviceName: String,
        connection: PortviewConnection,
        enrollment: EnrollmentAuthority?,
        sas: SASPairingControl?,
        control: HostControl?,
        pairings: PairingStore,
        emit: @escaping @Sendable (HostRunnerEvent) -> Void
    ) async -> Bool {
        guard let enrollment, let control, await sas?.isOpen() == true else { return false }
        let source = SASPairingControl.sourceKey(for: connection.resolvedRemoteEndpoint)
        guard let request = await enrollment.begin(
            publicKey: Data(publicKey), claimedName: deviceName, source: source, now: Date()) else { return false }
        emit(.enrollmentRequest(attemptID: request.attemptID, fingerprint: request.fingerprint,
                                claimedName: request.claimedName, expiresAt: request.expiresAt))
        // Re-check the window AT the decision point, not just at `begin` time (mirrors the gate's
        // own decision-time TOCTOU fix): an `approve()` that raced past an intervening window close
        // must not enroll — treated exactly like a deny.
        guard await enrollment.awaitDecision(request.attemptID), await sas?.isOpen() == true else {
            emit(.enrollmentResolved(attemptID: request.attemptID, approved: false))
            return false
        }
        do {
            try await pairings.enroll(publicKey: Data(publicKey), deviceName: deviceName)
        } catch {
            // Fail closed: an unpersistable enrollment must never proceed as authenticated — no
            // ServerHello, no scaffolding.
            emit(.enrollmentResolved(attemptID: request.attemptID, approved: false))
            emit(.message("Enrollment failed — keychain unavailable…"))
            return false
        }
        // Eager sweep (vs. the lazy one at the top of `serveSession`): a device just enrolled, so
        // any session still admitted under the now-superseded bootstrap policy loses access at once.
        control.evictLegacyAdmitted()
        emit(.enrollmentResolved(attemptID: request.attemptID, approved: true))
        return true
    }

    /// Serve the SAS pairing PREAMBLE on an unpinned connection: two-sided commit-then-reveal, then
    /// derive + emit the 6-digit code for the host HUD. Builds NONE of the streaming scaffolding
    /// (no clipboard/injector/capture/file). Only engages while a user-opened pairing window is live;
    /// each engagement counts against its remote source's attempt cap (with a window-wide ceiling
    /// bounding total guesses across sources). The connection carries only the
    /// SAS messages and is torn down here; the client compares the code and re-dials pinned.
    /// `internal` (not `private`) so the loopback integration test can drive it directly.
    static func serveSASPreamble(
        _ connection: PortviewConnection,
        clientCommit: SASClientCommit,
        inbound: MessageReader,
        hostCertSHA256: [UInt8],
        sas: SASPairingControl?,
        emit: @escaping @Sendable (HostRunnerEvent) -> Void
    ) async {
        defer { connection.close() }
        // Gate: only pair during a user-opened window, and cap attempts within it — per remote
        // source, so a flooder exhausts only its own budget instead of closing the window for the
        // legit device. The limiter itself closes the window when the window-wide ceiling is
        // exhausted, so a rejected attempt just drops this connection.
        guard let sas, await sas.isOpen() else { return }
        let source = SASPairingControl.sourceKey(for: connection.resolvedRemoteEndpoint)
        guard await sas.registerAttempt(source: source) else { return }

        // Host: fresh nonce + commit, sent before any reveal.
        let hostNonce = SASCode.randomNonce()
        let hostCommit = SASCode.commit(nonce: hostNonce, role: .host, certSHA256: hostCertSHA256)
        do { try await connection.send(.sasHostCommit(SASHostCommit(commit: hostCommit))) } catch { return }

        // Client reveal must come next; verify it against the client commit before using the nonce.
        // Deadline-bounded (rather than left to the ~30s QUIC idle timeout) so an idle/phantom
        // preamble connection can't sit here indefinitely — it hasn't claimed the display slot yet,
        // so a stalled peer no longer holds that slot hostage during this wait either.
        guard let next = await inbound.next(deadline: .seconds(5)),
              case .sasClientReveal(let reveal) = next else { return }
        guard SASCode.verify(commitment: clientCommit.commit, nonce: reveal.nonce,
                             role: .client, certSHA256: hostCertSHA256) else { return }

        // Claim the HUD's single code-display slot now that the client's reveal is verified, still
        // strictly BEFORE the host's own reveal is sent (must-fix 6): a second concurrent preamble
        // that loses the claim returns here, closing its connection, before its client ever derives
        // a code that isn't the one displayed. Claiming this late (rather than at engagement start)
        // keeps a silent/stalled connection from holding the display slot for the whole 5s wait
        // above. Released via its token on every exit.
        guard let displayToken = await sas.claimCodeDisplay(source: source) else { return }
        defer { Task { await sas.releaseCodeDisplay(token: displayToken) } }

        // Reveal the host nonce, then both sides derive the same code.
        do { try await connection.send(.sasHostReveal(SASHostReveal(nonce: hostNonce))) } catch { return }
        let code = SASCode.derive(clientNonce: reveal.nonce, hostNonce: hostNonce, certSHA256: hostCertSHA256)
        // Re-validate the lease immediately before displaying: `openWindow()` can force-release a
        // stale claim at any time, including the moment between the claim above and here, so a
        // holder that was stripped mid-flight must skip the emit rather than overwrite a newer
        // window's code with its own (the exact must-fix-6 DoS this lease exists to close).
        guard await sas.holdsCodeDisplay(token: displayToken) else { return }
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
    private static func makeInjector(for display: SCDisplay, cursorPump: CursorReportPump, capability: SessionCapability) -> InputInjector {
        let injector = InputInjector(displayBounds: CGDisplayBounds(display.displayID), capability: capability)
        injector.onCursorMoved = { nx, ny in cursorPump.report(nx, ny) }
        return injector
    }

    /// Capture → HEVC encode → serialize → send, routed per-lane: video/audio/stats each ride
    /// their secondary lane stream when the client bound one, and primary otherwise (see
    /// `HostLaneRouter`). The encoder is built to match the actual pixel-buffer dimensions
    /// (points vs pixels differ on Retina), and a single bad frame is skipped (re-requesting a
    /// keyframe) rather than aborting the whole stream.
    static func pumpVideo(
        _ router: HostLaneRouter,
        display: SCDisplay,
        capture: CaptureEngine,
        fps: Int = 60,
        bitrate: Int? = nil,
        feedback: ClientFeedbackHolder? = nil,
        capability: SessionCapability,
        emit: @escaping @Sendable (HostRunnerEvent) -> Void = { _ in }
    ) async {
        // Bounded wait for a lane-capable client's lane streams (HostLaneRouter.laneBindWait):
        // one that never opens them falls back to primary rather than stalling the session.
        // Instant for legacy sessions and on re-entry (display switch).
        await router.awaitLaneBindings()
        do {
            try capture.start(display: display, maxFPS: fps)
        } catch {
            logger.error("capture start error: \(error, privacy: .public)")
            return
        }

        // Forward system audio concurrently with video (audio lane when bound, else primary).
        // `capability.isValid` is checked IMMEDIATELY before the send (design §2/§4 finding
        // 4/H-e) — dropping just this frame, not tearing down the loop: the router's own
        // `capability.isValid` gate (a second, independent check) is the actual backstop, and
        // task cancellation (Task 8) is what eventually stops the loop itself.
        let audioTask = Task {
            for await audio in capture.audioFrames {
                guard capability.isValid else { continue }
                try? await router.send(.audioFrame(AudioFrame(
                    sampleRate: audio.sampleRate, channels: audio.channels,
                    ptsMicros: audio.ptsMicros, data: audio.data)), lane: .audio)
            }
        }
        defer { audioTask.cancel() }

        var encoder: VideoEncoder?
        var encoderWidth = 0
        var encoderHeight = 0
        var sequence: UInt64 = 0
        var pumpErrors = 0
        var needsKeyframe = true
        var stats = QualityStatsAccumulator()
        var rateController: AdaptiveRateController?
        var captureFPS = fps  // the fps actually applied to the SCStream

        for await frame in capture.frames {
            if Task.isCancelled { break }  // display switch / disconnect — stop this capture promptly
            let bufferWidth = CVPixelBufferGetWidth(frame.pixelBuffer)
            let bufferHeight = CVPixelBufferGetHeight(frame.pixelBuffer)
            if encoder == nil || bufferWidth != encoderWidth || bufferHeight != encoderHeight {
                do {
                    let rebuilt = try VideoEncoder(width: bufferWidth, height: bufferHeight, averageBitRate: bitrate)
                    encoder = rebuilt
                    encoderWidth = bufferWidth
                    encoderHeight = bufferHeight
                    needsKeyframe = true
                    // (Re)seed the adaptive controller from THIS encoder's starting bitrate (the
                    // width·height heuristic in Auto, the pinned value otherwise): a rebuild is a
                    // new stream size, so adaptation restarts from its setpoint. Seeding with the
                    // frame's own crop fraction applies the crop boost immediately (bead s86) —
                    // the zoomed region never encodes a stats interval at the unboosted heuristic.
                    // Congestion attenuation still does not survive a zoom-rung crossing.
                    let seeded = AdaptiveRateController(
                        mode: bitrate == nil ? .auto : .pinned,
                        bitrateSetpoint: rebuilt.averageBitRate,
                        fpsCeiling: fps,
                        initialCropFraction: frame.region.width * frame.region.height)
                    rateController = seeded
                    if seeded.currentTargets.bitrate != rebuilt.averageBitRate {
                        rebuilt.setAverageBitRate(seeded.currentTargets.bitrate)
                    }
                    logger.info("Encoder ready for \(bufferWidth, privacy: .public)x\(bufferHeight, privacy: .public) buffers.")
                } catch {
                    logger.error("encoder create error: \(error, privacy: .public)")
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
                // Primary-path errors still land in this loop's catch below (encoder rebuild +
                // keyframe); a video-LANE error is absorbed by the router's flip, which forces
                // the keyframe itself through the capture's request path. `capability.isValid` is
                // checked IMMEDIATELY before this send (design §2/§4 finding 4/H-e) — the live
                // code previously checked only `Task.isCancelled`, and only before the encode, so
                // a frame encoded the instant before revoke still sent.
                if capability.isValid {
                    try await router.send(.videoFrame(VideoFrame(
                        sequence: sequence,
                        ptsMicros: UInt64(max(0, CMTimeGetSeconds(frame.pts)) * 1_000_000),
                        isKeyframe: sample.isKeyframe,
                        displayID: UInt32(display.displayID),
                        width: UInt32(bufferWidth), height: UInt32(bufferHeight),
                        data: payload,
                        viewportNormalizedX: viewport.minX, viewportNormalizedY: viewport.minY,
                        viewportNormalizedW: viewport.width, viewportNormalizedH: viewport.height
                    )), lane: .video)
                }
                let liveViewport = await capture.currentViewport()
                if let quality = stats.snapshotIfDue(
                    displayID: UInt32(display.displayID),
                    encoderWidth: encoderWidth,
                    encoderHeight: encoderHeight,
                    configuredBitrate: activeEncoder.averageBitRate,
                    viewport: liveViewport
                ) {
                    // Stats ride the stats lane for lane-capable clients (a video burst can't
                    // delay the HUD); old-version sessions keep them on primary as today.
                    // `capability.isValid` is checked IMMEDIATELY before this send too (its own
                    // independent post-encode gate, not inherited from the video check above).
                    if capability.isValid {
                        try? await router.send(.qualityStats(quality), lane: .stats)
                    }
                    emit(.sessionStats(HostSessionStats(
                        throughputMbps: quality.encodedMbps,
                        fps: quality.fps,
                        encodeMs: quality.averageEncodeMs,
                        displayWidth: display.width,
                        displayHeight: display.height)))
                    // Steer next interval's bitrate + capture fps off the freshest client feedback
                    // plus the SNAPPED crop area (bead 90p: a tight crop boosts the setpoint so
                    // zoomed text stays crisp; Auto mode only — see AdaptiveRateController). The
                    // bitrate applies to the LIVE VideoToolbox session (no rebuild); fps retargets
                    // via SCStream reconfigure.
                    if let targets = rateController?.evaluate(AdaptiveRateController.Inputs(
                        feedback: feedback?.latest(), hostStats: quality,
                        cropFraction: liveViewport.width * liveViewport.height)) {
                        if targets.bitrate != activeEncoder.averageBitRate {
                            activeEncoder.setAverageBitRate(targets.bitrate)
                        }
                        if targets.fps != captureFPS, await capture.setMaxFPS(targets.fps) {
                            captureFPS = targets.fps
                        }
                    }
                }
            } catch {
                // Drop the wedged encoder so the next frame rebuilds a fresh VideoToolbox session
                // (the startup path); keeping it would re-enter the same broken session every frame.
                encoder = nil
                needsKeyframe = true
                if sequence == 0 { logger.warning("frame skipped (will rebuild encoder): \(error, privacy: .public)") }
                pumpErrors += 1
                if pumpErrors % 60 == 1 {
                    logger.notice("pump error #\(pumpErrors, privacy: .public) seq=\(sequence, privacy: .public): \(error, privacy: .public)")
                }
            }
            if sequence > 0, sequence % 120 == 0 {
                logger.notice("pump alive seq=\(sequence, privacy: .public) errors=\(pumpErrors, privacy: .public)")
            }
        }
        logger.notice("pump exit seq=\(sequence, privacy: .public) cancelled=\(Task.isCancelled, privacy: .public)")
        capture.stop()
    }
}

// SPDX-License-Identifier: Apache-2.0
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import LocalAuthentication
import Observation
import PortviewHostCore
import PortviewTransport

@MainActor
@Observable
final class HostAppModel {
    enum State: Equatable {
        case idle
        case starting
        case ready(HostReadyDetails)
        case failed(String)

        var title: String {
            switch self {
            case .idle: "Idle"
            case .starting: "Starting host..."
            case .ready: "Host ready"
            case .failed: "Host failed"
            }
        }
    }

    private static let displayName = "Portview Host"

    var state: State = .idle
    var accessibilityWarning: String?
    var messages: [String] = []
    /// Live connected-device session state (count, primary device name, latest telemetry).
    private(set) var sessions = HostSessions()
    /// When the current client session began (for the "connected mm:ss" readout); nil when none.
    private(set) var connectedSince: Date?
    /// Real, polled permission status (not inferred from run state) — drives guided onboarding.
    private(set) var screenRecordingGranted = false
    private(set) var accessibilityGranted = false

    /// Guided onboarding derived from the live permission bools.
    var onboarding: PermissionsOnboarding {
        PermissionsOnboarding(screenRecordingGranted: screenRecordingGranted, accessibilityGranted: accessibilityGranted)
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let control = HostControl()
    @ObservationIgnored private let sasControl = SASPairingControl()
    /// The ONE shared enrollment-ceremony authority (han.3 design) — constructed once here (not
    /// per-`start()`) so `beginPairing`/`endPairing` and the Allow/Deny actions all resolve against
    /// the same actor state; passed into `events(...)` below beside the app's `PairingStore`.
    @ObservationIgnored private let authority = EnrollmentAuthority()
    @ObservationIgnored private var permissionsTask: Task<Void, Never>?
    @ObservationIgnored private var pairingTimeoutTask: Task<Void, Never>?
    /// CloudKit re-wake beacon (fire-and-forget; each trigger runs in its own task so an iCloud stall
    /// can never touch hosting). Writes only on explicit triggers — hosting ready + the menu-bar
    /// "Ask iPhone to reconnect" nudge — never on a timer.
    @ObservationIgnored private let beaconWriter = HostBeaconWriter(store: CloudKitBeaconStore())

    /// True while a user-opened SAS pairing window is live (gates the preamble + the displayed code).
    private(set) var isPairing = false
    /// The 6-digit SAS code to show the user (never logged); nil unless a preamble derived one.
    private(set) var displayedSASCode: String?
    /// Transient "✓ a client confirmed" signal (Guardrail E). Does NOT close the window — the window
    /// closes only via the pinned re-dial's `.deviceConnected`, the timeout, the cap, or stop.
    private(set) var clientConfirmed = false
    /// How long a pairing window stays open before auto-closing.
    private static let pairingWindowSeconds: TimeInterval = 120

    /// The single in-flight enrollment prompt (han.3), or nil when none is pending. Set by
    /// `.enrollmentRequest`, cleared by `.enrollmentResolved` — the L1 no-false-success path: a
    /// prompt must never outlive the request it was raised for.
    private(set) var enrollmentPrompt: (attemptID: UUID, fingerprint: String, claimedName: String, expiresAt: Date)?

    /// Observed (not derived from the @ObservationIgnored task) so the menu-bar glyph + Start/Stop
    /// re-render on EVERY transition — including when the serve loop ends on its own while ready.
    private(set) var isRunning = false
    var screenRecordingHelp: String { HostRunner.screenRecordingHelp(for: .app(displayName: Self.displayName)) }

    /// Menu-bar glyph reflecting state at a glance (reads observed state + sessions → auto-updates).
    var menuBarSymbol: String {
        let failed: Bool = if case .failed = state { true } else { false }
        return HostMenuBar.symbol(isFailed: failed, isRunning: isRunning, connectedCount: sessions.count)
    }

    func start() {
        guard task == nil else { return }
        isRunning = true
        state = .starting
        accessibilityWarning = nil
        messages = []
        sessions = HostSessions()
        connectedSince = nil

        task = Task { [weak self, control, sasControl, authority] in
            // Legacy-bootstrap until first-enroll auto-promotion flips this host to `.required`
            // (han.3 revisits the open-ended expiry). This PairingStore is the ONE shared
            // authority — han.4's revoke UI must use this same instance, never construct their
            // own. `authority` is likewise the ONE shared EnrollmentAuthority (see its stored
            // property comment above).
            let events = HostRunner().events(identity: .app(displayName: Self.displayName), control: control, sasControl: sasControl,
                                             authPolicy: .legacyBootstrap(expiresAt: .distantFuture),
                                             pairings: PairingStore(),
                                             enrollment: authority)
            for await event in events {
                self?.handle(event)
            }
            guard let self else { return }
            self.task = nil
            self.isRunning = false
            if self.state == .starting {
                self.state = .idle
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        state = .idle
        sessions = HostSessions()
        connectedSince = nil
        endPairing()
    }

    /// User opened a pairing window: clients may now run the SAS preamble and the host will display a
    /// code. Auto-closes after `pairingWindowSeconds` so an idle code can't linger.
    ///
    /// Legacy barrier (design v2, review H3/Sol-1): evict every legacy-admitted session and reset the
    /// enrollment authority's epoch BEFORE the SAS window opens — no remote peer can be mid-session
    /// (able to watch the ceremony or click Deny) once pairing UI becomes reachable.
    func beginPairing() {
        guard isRunning else { return }
        control.evictLegacyAdmitted()
        Task { [authority, sasControl] in
            await authority.windowOpened()
            await sasControl.openWindow()
        }
        isPairing = true
        displayedSASCode = nil
        clientConfirmed = false
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pairingWindowSeconds))
            guard let self, !Task.isCancelled else { return }
            self.endPairing()
        }
    }

    /// Close the pairing window and clear the displayed code (manual cancel / timeout / connect / stop).
    func endPairing() {
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        Task { await sasControl.closeWindow() }
        Task { await authority.windowClosed() }
        isPairing = false
        displayedSASCode = nil
        clientConfirmed = false
    }

    /// Allow: gates every approval behind genuine LOCAL presence — LAContext is evaluated fresh per
    /// tap, and only a POSITIVE result reaches `authority.approve`. Failure or cancel leaves the
    /// prompt exactly as-is (no false success); it clears only via `.enrollmentResolved` (approve,
    /// deny, the ceremony's internal deadline, or window close).
    func approveEnrollment(_ attemptID: UUID) {
        Task { [authority] in
            let context = LAContext()
            let approved = (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                               localizedReason: "Approve pairing this device")) ?? false
            guard approved else { return }
            await authority.approve(attemptID)
        }
    }

    /// Deny: no local-presence check — a user can always reject a prompt outright.
    func denyEnrollment(_ attemptID: UUID) {
        Task { [authority] in await authority.deny(attemptID) }
    }

    /// Close the connected client session(s) without stopping hosting (keeps advertising).
    func disconnectClients() {
        control.disconnectAll()
    }

    /// The nudge is only offered when it can actually reach iCloud: the process carries the
    /// CloudKit entitlement (default dev builds don't — `PORTVIEW_HOST_ENTITLEMENTS` is opt-in)
    /// AND hosting reached `.ready` (before that the writer has no identity and drops the write).
    /// Gating here keeps the fail-soft rule honest: no success message for a write that never
    /// happened.
    var canAskReconnect: Bool {
        guard case .ready = state else { return false }
        return CloudKitBeaconStore.isAvailable
    }

    /// Menu-bar nudge: write a `wantsReconnect` beacon so the paired iPhone gets a silent push and
    /// offers tap-to-resume. Only meaningful once ready (the menu row is hidden otherwise).
    func askIPhoneToReconnect() {
        guard canAskReconnect else { return }
        let writer = beaconWriter
        Task { await writer.requestReconnect() }
        messages.append("asked iPhone to reconnect (via iCloud)")
    }

    /// Pick a file and send it to the connected iPhone (Mac→iPhone transfer).
    func sendFileToClient() {
        guard let target = sessions.devices.first?.id else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else {
            messages.append("couldn't read \(url.lastPathComponent)")
            return
        }
        control.sendFile(name: url.lastPathComponent, data: data, to: target)
        messages.append("sending \(url.lastPathComponent) → iPhone")
    }

    func copyPairingURL() {
        guard case .ready(let details) = state else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(details.pairingURL, forType: .string)
    }

    func openScreenRecordingSettings() {
        openPrivacyPane(anchor: "Privacy_ScreenCapture")
    }

    func openAccessibilitySettings() {
        openPrivacyPane(anchor: "Privacy_Accessibility")
    }

    /// Read the CURRENT permission status without prompting (the prompt is owned once by HostRunner).
    func refreshPermissions() {
        let screenRecording = CGPreflightScreenCaptureAccess()
        let accessibility = AXIsProcessTrusted()
        if screenRecording != screenRecordingGranted { screenRecordingGranted = screenRecording }
        if accessibility != accessibilityGranted { accessibilityGranted = accessibility }
    }

    /// Poll permission status every 2s (idempotent; runs for the app's lifetime once started, NOT
    /// tied to the window — hosting and the menu bar outlive the window, so monitoring must too).
    /// Accessibility flips live; Screen Recording shows granted only after relaunch (onboarding copy
    /// says so). An immediate refresh on each call keeps a freshly-shown surface accurate.
    func startPermissionMonitoring() {
        refreshPermissions()
        guard permissionsTask == nil else { return }
        permissionsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.refreshPermissions()
            }
        }
    }

    private func handle(_ event: HostRunnerEvent) {
        switch event {
        case .ready(let details):
            state = .ready(details)
            // Hosting-start beacon trigger. This also subsumes the spec's port-change trigger: the
            // persisted port can only change at a listener (re)bind, and every bind path re-emits
            // `.ready` carrying the actual bound port — if a future change lets the port move
            // MID-RUN, wire `beaconWriter.portChanged(_:)` there. Reuses the pin fingerprint hex
            // the runner computed for the pairing payload as the record name. Own task: a CloudKit
            // outage must never block event handling or the serve path.
            let writer = beaconWriter
            Task {
                await writer.hostingStarted(pinHex: details.pinHex, hostName: details.serviceName,
                                            port: details.port)
            }
        case .message(let message):
            messages.append(message)
        case .accessibilityWarning(let warning):
            accessibilityWarning = warning
        case .failed(let message):
            state = .failed(message)
            messages.append(message)
        case .sasCode(let code):
            // Only show it if the window is still open (the emit hops to the main actor; the window
            // could have just timed out/closed in that gap — don't resurrect a cleared code).
            if isPairing { displayedSASCode = code }  // shown on the HUD; never logged
        case .sasConfirmed:
            // Positive signal only — do NOT close the shared window (a relayed confirm from any peer
            // must not be able to close it). The window closes via .deviceConnected/timeout/cap/stop.
            if isPairing { clientConfirmed = true }
        case .deviceConnected, .deviceDisconnected, .sessionStats:
            let wasConnected = sessions.count > 0
            sessions.apply(event)
            let nowConnected = sessions.count > 0
            if nowConnected, !wasConnected { connectedSince = Date() }
            if !nowConnected { connectedSince = nil }
            if case .deviceConnected(_, let name) = event {
                messages.append("device connected · \(name)")
                endPairing()  // a client paired → close the window + clear the code
            }
            if case .deviceDisconnected = event { messages.append("device disconnected") }
        case .enrollmentRequest(let attemptID, let fingerprint, let claimedName, let expiresAt):
            enrollmentPrompt = (attemptID: attemptID, fingerprint: fingerprint, claimedName: claimedName, expiresAt: expiresAt)
        case .enrollmentResolved(let attemptID, _):
            // Only clear if this resolution is for the prompt currently shown — a prompt must
            // never outlive its own request (L1 no-false-success path).
            if enrollmentPrompt?.attemptID == attemptID { enrollmentPrompt = nil }
        }
    }

    private func openPrivacyPane(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

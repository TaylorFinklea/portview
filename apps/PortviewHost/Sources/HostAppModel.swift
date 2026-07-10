// SPDX-License-Identifier: Apache-2.0
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Observation
import PortviewHostCore

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
    @ObservationIgnored private var permissionsTask: Task<Void, Never>?
    @ObservationIgnored private var pairingTimeoutTask: Task<Void, Never>?

    /// True while a user-opened SAS pairing window is live (gates the preamble + the displayed code).
    private(set) var isPairing = false
    /// The 6-digit SAS code to show the user (never logged); nil unless a preamble derived one.
    private(set) var displayedSASCode: String?
    /// Transient "✓ a client confirmed" signal (Guardrail E). Does NOT close the window — the window
    /// closes only via the pinned re-dial's `.deviceConnected`, the timeout, the cap, or stop.
    private(set) var clientConfirmed = false
    /// How long a pairing window stays open before auto-closing.
    private static let pairingWindowSeconds: TimeInterval = 120

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

        task = Task { [weak self, control, sasControl] in
            let events = HostRunner().events(identity: .app(displayName: Self.displayName), control: control, sasControl: sasControl)
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
    func beginPairing() {
        guard isRunning else { return }
        Task { await sasControl.openWindow() }
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
        isPairing = false
        displayedSASCode = nil
        clientConfirmed = false
    }

    /// Close the connected client session(s) without stopping hosting (keeps advertising).
    func disconnectClients() {
        control.disconnectAll()
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
        }
    }

    private func openPrivacyPane(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

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
    @ObservationIgnored private var permissionsTask: Task<Void, Never>?

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

        task = Task { [weak self, control] in
            let events = HostRunner().events(identity: .app(displayName: Self.displayName), control: control)
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
        case .deviceConnected, .deviceDisconnected, .sessionStats:
            let wasConnected = sessions.count > 0
            sessions.apply(event)
            let nowConnected = sessions.count > 0
            if nowConnected, !wasConnected { connectedSince = Date() }
            if !nowConnected { connectedSince = nil }
            if case .deviceConnected(_, let name) = event { messages.append("device connected · \(name)") }
            if case .deviceDisconnected = event { messages.append("device disconnected") }
        }
    }

    private func openPrivacyPane(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

import AppKit
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

    @ObservationIgnored private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }
    var screenRecordingHelp: String { HostRunner.screenRecordingHelp(for: .app(displayName: Self.displayName)) }

    func start() {
        guard task == nil else { return }
        state = .starting
        accessibilityWarning = nil
        messages = []

        task = Task { [weak self] in
            let events = HostRunner().events(identity: .app(displayName: Self.displayName))
            for await event in events {
                self?.handle(event)
            }
            guard let self else { return }
            self.task = nil
            if self.state == .starting {
                self.state = .idle
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        state = .idle
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
        }
    }

    private func openPrivacyPane(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

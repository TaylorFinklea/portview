// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Pure settings logic: port text validation and launch-at-login transitions with inline errors.
/// Never reports a state it did not observe: after every transition the status is re-read from the
/// controller, and a failure surfaces `launchAtLoginError` instead of faking success.
@MainActor
final class HostSettingsCoordinator: ObservableObject {
    @Published private(set) var launchAtLogin: LaunchAtLoginStatus
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var portError: String?

    let store: HostPreferencesStore
    private let controller: LaunchAtLoginControlling

    init(store: HostPreferencesStore, launchAtLogin controller: LaunchAtLoginControlling) {
        self.store = store
        self.controller = controller
        self.launchAtLogin = controller.status
    }

    /// The display the picker should show as selected: the remembered one only while it is still
    /// attached, otherwise `nil` (= Automatic) so a stale choice never renders as live.
    nonisolated static func displaySelection(preferred: UInt32?, available: [UInt32]) -> UInt32? {
        guard let preferred, available.contains(preferred) else { return nil }
        return preferred
    }

    /// Re-read the OS state (e.g. when the settings view appears).
    func refreshLaunchAtLogin() {
        launchAtLogin = controller.status
    }

    /// Request a transition; calls the controller once. On failure the published status is the
    /// controller's real current state and `launchAtLoginError` explains.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try controller.setEnabled(enabled)
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Couldn't \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = controller.status
    }

    /// Blank (after trimming) = automatic. Otherwise digits only, 1...65535. Invalid text sets
    /// `portError` and leaves the persisted value untouched. Returns whether the text was accepted.
    @discardableResult
    func commitPort(text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            store.preferences.preferredPort = nil
            portError = nil
            return true
        }
        guard trimmed.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = UInt16(trimmed), value >= 1 else {
            portError = "Enter a port from 1 to 65535, or leave blank for automatic."
            return false
        }
        store.preferences.preferredPort = value
        portError = nil
        return true
    }
}

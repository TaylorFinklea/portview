// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Pure derivation of the host's guided permission onboarding from the two real grant bools (Screen
/// Recording + Accessibility). Lives in core (no AppKit) so it is unit-tested; the app layer
/// (`HostAppModel`) supplies the live bools and renders `title`/`body`/`primaryPane`.
///
/// Screen Recording is the gate (required for viewing AND needs an app relaunch to take effect after
/// granting); Accessibility (remote control) follows and takes effect live.
public struct PermissionsOnboarding: Equatable, Sendable {
    public enum Step: Equatable, Sendable { case complete, screenRecording, accessibility }
    public enum SettingsPane: Equatable, Sendable { case screenRecording, accessibility }

    public let screenRecordingGranted: Bool
    public let accessibilityGranted: Bool

    public init(screenRecordingGranted: Bool, accessibilityGranted: Bool) {
        self.screenRecordingGranted = screenRecordingGranted
        self.accessibilityGranted = accessibilityGranted
    }

    public var step: Step {
        if !screenRecordingGranted { return .screenRecording }
        if !accessibilityGranted { return .accessibility }
        return .complete
    }

    public var allGranted: Bool { screenRecordingGranted && accessibilityGranted }

    /// Only Screen Recording needs a relaunch after granting; Accessibility flips live.
    public var requiresRelaunch: Bool { step == .screenRecording }

    public var primaryPane: SettingsPane? {
        switch step {
        case .screenRecording: return .screenRecording
        case .accessibility: return .accessibility
        case .complete: return nil
        }
    }

    public var title: String {
        switch step {
        case .screenRecording: return "Allow Portview to see your screen"
        case .accessibility: return "Allow Portview to control this Mac"
        case .complete: return ""
        }
    }

    public var body: String {
        switch step {
        case .screenRecording:
            return "Grant Screen Recording in System Settings, then quit and reopen Portview for it to take effect."
        case .accessibility:
            return "Grant Accessibility in System Settings to enable keyboard & mouse control. Viewing works without it."
        case .complete:
            return ""
        }
    }
}

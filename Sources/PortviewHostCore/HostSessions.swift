// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A client device currently in a session with the host.
public struct ConnectedDevice: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Live telemetry for the connected-device card. All real: throughput/fps/encode come from the
/// host's `QualityStatsAccumulator`, the dimensions from the captured display.
public struct HostSessionStats: Equatable, Sendable {
    public var throughputMbps: Double
    public var fps: Double
    public var encodeMs: Double
    public var displayWidth: Int
    public var displayHeight: Int

    public init(throughputMbps: Double, fps: Double, encodeMs: Double, displayWidth: Int, displayHeight: Int) {
        self.throughputMbps = throughputMbps
        self.fps = fps
        self.encodeMs = encodeMs
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
    }
}

/// Pure reducer that folds `HostRunnerEvent`s into the host's connected-session state. Keeping the
/// derivation here (rather than ad hoc in the view model) makes it unit-testable without AppKit.
public struct HostSessions: Equatable, Sendable {
    public private(set) var devices: [ConnectedDevice] = []
    public private(set) var latestStats: HostSessionStats?

    public init() {}

    /// Number of connected devices.
    public var count: Int { devices.count }
    /// The first (longest-connected) device's name, shown on the connected card.
    public var primaryName: String? { devices.first?.name }

    public mutating func apply(_ event: HostRunnerEvent) {
        switch event {
        case .deviceConnected(let id, let name):
            if !devices.contains(where: { $0.id == id }) {
                devices.append(ConnectedDevice(id: id, name: name))
            }
        case .deviceDisconnected(let id):
            devices.removeAll { $0.id == id }
            if devices.isEmpty { latestStats = nil } // no session → no live telemetry
        case .sessionStats(let stats):
            latestStats = stats
        case .message, .ready, .accessibilityWarning, .failed, .sasCode, .sasConfirmed,
             .enrollmentRequest, .enrollmentResolved:
            break  // SAS/enrollment HUD-display state is handled by the app, not session state
        }
    }
}

/// Pure presentation formatting shared by the host UI.
public enum HostFormat {
    /// The pairing pin grouped for display: first two 4-char quads, an ellipsis, then the last quad
    /// (e.g. `3f9a 1c0e … b27c`). Pins shorter than 12 chars are returned unchanged.
    public static func groupedPin(_ pin: String) -> String {
        guard pin.count >= 12 else { return pin }
        let chars = Array(pin)
        let first = String(chars[0..<4])
        let second = String(chars[4..<8])
        let last = String(chars[(chars.count - 4)...])
        return "\(first) \(second) … \(last)"
    }

    /// Elapsed session time as `mm:ss` (minutes are not clamped to 60).
    public static func sessionDuration(_ seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        let secs = max(0, seconds) % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
}

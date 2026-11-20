// SPDX-License-Identifier: Apache-2.0
import Combine
import Foundation

/// The host's persisted user preferences. Privacy-sensitive channels default OFF.
/// Launch-at-login is deliberately NOT here: the OS owns that state (see `LaunchAtLoginControlling`).
struct HostPreferences: Codable, Equatable, Sendable {
    /// `nil` = automatic (let the system pick a port).
    var preferredPort: UInt16?
    /// `nil` = automatic (main display).
    var preferredDisplayID: UInt32?
    var clipboardEnabled: Bool
    var fileTransferEnabled: Bool

    static let defaults = HostPreferences(
        preferredPort: nil, preferredDisplayID: nil,
        clipboardEnabled: false, fileTransferEnabled: false)
}

/// Publishes one `HostPreferences` value and writes it through to `UserDefaults` on every change.
/// A missing or undecodable stored value yields `HostPreferences.defaults`.
@MainActor
final class HostPreferencesStore: ObservableObject {
    static let defaultsKey = "host.preferences.v1"

    @Published var preferences: HostPreferences {
        didSet {
            guard preferences != oldValue else { return }
            if let data = try? JSONEncoder().encode(preferences) {
                defaults.set(data, forKey: Self.defaultsKey)
            }
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(HostPreferences.self, from: data) {
            preferences = decoded
        } else {
            preferences = .defaults
        }
    }
}

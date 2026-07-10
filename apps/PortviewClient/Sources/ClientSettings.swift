// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Persisted client stream-quality preferences, applied to the `StartSession` handshake. The host
/// honors these (capture fps + encoder bitrate, see `StreamParameters` host-side), so changing them
/// and reconnecting actually changes the stream.
struct ClientSettings: Codable, Equatable {
    /// 0 = Auto: let the host pick its own (high) bitrate heuristic. Otherwise a Mbps ceiling within
    /// `bitrateRange`. Default Auto, so we never request *less* than the host would choose itself.
    var bitrateMbps: Int = 0
    var fps: Int = 60

    static let bitrateRange = 4...80
    static let fpsOptions = [30, 60]

    /// Encoder bitrate (bits/s) for the handshake; 0 ("Auto") → the host uses its own heuristic.
    var targetBitrate: UInt32 {
        guard bitrateMbps > 0 else { return 0 }
        return UInt32(min(Self.bitrateRange.upperBound, max(Self.bitrateRange.lowerBound, bitrateMbps))) * 1_000_000
    }

    /// Capture frame rate for the handshake (one of the offered options; defaults to 60).
    var maxFPS: UInt16 {
        UInt16(Self.fpsOptions.contains(fps) ? fps : 60)
    }
}

extension ClientSettings {
    private static let defaultsKey = "portview.clientSettings"

    static func load() -> ClientSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(ClientSettings.self, from: data) else {
            return ClientSettings()
        }
        return decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: ClientSettings.defaultsKey)
        }
    }
}

/// Observable wrapper for the settings UI; persists on every change.
@MainActor
final class ClientSettingsStore: ObservableObject {
    @Published var settings: ClientSettings {
        didSet { settings.save() }
    }
    init() { settings = ClientSettings.load() }
}

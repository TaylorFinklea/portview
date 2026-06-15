import Foundation

/// Persisted client stream-quality preferences, applied to the `StartSession` handshake. The host
/// honors these (capture fps + encoder bitrate, see `StreamParameters` host-side), so changing them
/// and reconnecting actually changes the stream.
struct ClientSettings: Codable, Equatable {
    var bitrateMbps: Int = 25
    var fps: Int = 60

    static let bitrateRange = 4...80
    static let fpsOptions = [30, 60]

    /// Encoder bitrate (bits/s) for the handshake, clamped to the offered range.
    var targetBitrate: UInt32 {
        UInt32(min(Self.bitrateRange.upperBound, max(Self.bitrateRange.lowerBound, bitrateMbps))) * 1_000_000
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

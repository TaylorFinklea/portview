// SPDX-License-Identifier: Apache-2.0
import Foundation
import Network
import PortviewTransport

/// A Mac the user has successfully paired with, persisted for one-tap reconnect.
struct SavedHost: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var host: String
    var port: UInt16
    var pinHex: String

    var payload: PairingPayload {
        PairingPayload(host: host, port: port, pinHex: pinHex, name: name)
    }

    /// Ordered connection candidates for reconnecting this Mac. A live Bonjour host matching by
    /// name comes first (its service endpoint re-resolves to the current address, so reconnect
    /// survives a LAN IP change); the saved `host:port` follows as the off-LAN / fallback path.
    /// The pin is unchanged either way, so certificate pinning still anchors trust — the Bonjour
    /// name is only a routing hint, never a trust decision.
    func reconnectEndpoints(among discovered: [DiscoveredHost]) -> [NWEndpoint] {
        var endpoints: [NWEndpoint] = []
        if let match = discovered.first(where: { $0.name == name }) {
            endpoints.append(match.endpoint)
        }
        if let nwPort = NWEndpoint.Port(rawValue: port) {
            endpoints.append(.hostPort(host: NWEndpoint.Host(host), port: nwPort))
        }
        return endpoints
    }

    /// Whether this saved Mac is currently discoverable on the LAN (a live Bonjour host matches by
    /// name). Drives the Deck Home tile's reachability treatment: on-network (signal) vs off (idle).
    func isOnNetwork(among discovered: [DiscoveredHost]) -> Bool {
        discovered.contains { $0.name == name }
    }
}

/// Persists paired hosts in `UserDefaults` so returning users skip the QR rescan.
@MainActor
final class SavedHostsStore: ObservableObject {
    @Published private(set) var hosts: [SavedHost] = []
    nonisolated private static let defaultsKey = "portview.savedHosts"
    private let defaults = UserDefaults.standard

    init() { load() }

    /// Upsert (match by name first, then host+port), keeping the existing id, and move to the front
    /// as most-recent. Matching by name lets a saved Mac that moved to a new IP refresh in place
    /// (rather than creating a duplicate) when it reconnects via Bonjour.
    func remember(name: String, host: String, port: UInt16, pinHex: String) {
        let entry = SavedHost(name: name.isEmpty ? host : name, host: host, port: port, pinHex: pinHex)
        hosts = Self.upserting(hosts, with: entry)
        save()
    }

    /// Pure upsert used by `remember` (and unit-tested without touching UserDefaults).
    nonisolated static func upserting(_ hosts: [SavedHost], with entry: SavedHost) -> [SavedHost] {
        var result = hosts
        var newEntry = entry
        // Match by name, then host:port, then the pinned cert (stable per Mac) — so a Mac first
        // saved manually (name == its IP) folds into one entry when later seen via Bonjour under its
        // real name + a new IP, instead of leaving a stale duplicate.
        let match = result.firstIndex { $0.name == entry.name }
            ?? result.firstIndex { $0.host == entry.host && $0.port == entry.port }
            ?? result.firstIndex { $0.pinHex == entry.pinHex }
        if let match {
            newEntry.id = result[match].id
            result.remove(at: match)
        }
        result.insert(newEntry, at: 0)
        return result
    }

    func remember(_ payload: PairingPayload) {
        remember(name: payload.name ?? payload.host, host: payload.host, port: payload.port, pinHex: payload.pinHex)
    }

    func remove(atOffsets offsets: IndexSet) {
        hosts.remove(atOffsets: offsets)
        save()
    }

    func removeAll() {
        hosts.removeAll()
        save()
    }

    /// Decode the persisted hosts outside the MainActor store — the CloudKit re-wake background
    /// handler runs while the UI (and this store) may not exist. Same key/decoder as `load()`.
    nonisolated static func snapshot() -> [SavedHost] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([SavedHost].self, from: data) else { return [] }
        return decoded
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([SavedHost].self, from: data) else { return }
        hosts = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(hosts) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

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
    private let defaultsKey = "portview.savedHosts"
    private let defaults = UserDefaults.standard

    init() { load() }

    /// Upsert by host+port (keeping the existing id), then move to the front as most-recent.
    func remember(name: String, host: String, port: UInt16, pinHex: String) {
        var entry = SavedHost(name: name.isEmpty ? host : name, host: host, port: port, pinHex: pinHex)
        if let index = hosts.firstIndex(where: { $0.host == host && $0.port == port }) {
            entry.id = hosts[index].id
            hosts.remove(at: index)
        }
        hosts.insert(entry, at: 0)
        save()
    }

    func remember(_ payload: PairingPayload) {
        remember(name: payload.name ?? payload.host, host: payload.host, port: payload.port, pinHex: payload.pinHex)
    }

    func remove(atOffsets offsets: IndexSet) {
        hosts.remove(atOffsets: offsets)
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([SavedHost].self, from: data) else { return }
        hosts = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(hosts) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}

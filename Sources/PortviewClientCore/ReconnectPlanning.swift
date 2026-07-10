// SPDX-License-Identifier: Apache-2.0
import Network
import PortviewTransport

/// Pure planning helpers for re-binding a dropped session and persisting where it connected.
public enum ReconnectPlanning {
    /// Extract a concrete host:port from a connection's resolved endpoint (only `.hostPort` yields
    /// one — a `.service`/`.host`/nil endpoint returns nil). Pure for unit testing.
    public static func hostPort(from endpoint: NWEndpoint?) -> (host: String, port: UInt16)? {
        guard let endpoint, case let .hostPort(host, port) = endpoint else { return nil }
        let hostString: String
        switch host {
        case .ipv4(let address): hostString = "\(address)"
        case .ipv6(let address): hostString = "\(address)"
        case .name(let name, _): hostString = name
        @unknown default: hostString = "\(host)"
        }
        return (hostString, port.rawValue)
    }

    /// Reconnect candidates, ordered: a live Bonjour host matching by name (re-resolves the current
    /// IP after a LAN change) first, then the endpoint we were connected to as the fallback. Pure
    /// so it is unit-testable and callable off the main actor.
    public static func reconnectCandidates(
        name: String, fallback: NWEndpoint, discovered: [DiscoveredHost]
    ) -> [NWEndpoint] {
        var endpoints: [NWEndpoint] = []
        if let match = discovered.first(where: { $0.name == name }) {
            endpoints.append(match.endpoint)
        }
        if !endpoints.contains(fallback) {
            endpoints.append(fallback)
        }
        return endpoints
    }
}

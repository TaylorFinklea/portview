// SPDX-License-Identifier: Apache-2.0
import Network
import PortviewTransport
import XCTest

@testable import PortviewClient

final class ReconnectEndpointsTests: XCTestCase {
    private func saved(name: String = "Roshar", host: String = "10.0.0.5", port: UInt16 = 54321) -> SavedHost {
        SavedHost(name: name, host: host, port: port, pinHex: String(repeating: "a", count: 64))
    }

    private func discovered(_ name: String) -> DiscoveredHost {
        DiscoveredHost(
            id: name, name: name,
            endpoint: .service(name: name, type: "_portview._udp", domain: "local.", interface: nil))
    }

    /// A live Bonjour host matching by name comes first (survives a LAN IP change), then the saved
    /// host:port as the off-LAN / fallback candidate.
    func testPrefersNameMatchedDiscoveredEndpointThenSavedIP() {
        let endpoints = saved(name: "Roshar")
            .reconnectEndpoints(among: [discovered("Other"), discovered("Roshar")])

        XCTAssertEqual(endpoints.count, 2)
        XCTAssertEqual(endpoints.first, discovered("Roshar").endpoint)
        XCTAssertEqual(endpoints.last, .hostPort(host: "10.0.0.5", port: 54321))
    }

    /// No matching discovered host → only the saved host:port (today's behavior, unchanged).
    func testNoNameMatchUsesOnlySavedIP() {
        let endpoints = saved(name: "Roshar").reconnectEndpoints(among: [discovered("Other")])
        XCTAssertEqual(endpoints, [.hostPort(host: "10.0.0.5", port: 54321)])
    }

    /// Empty discovery (off-LAN / not yet browsed) → only the saved host:port.
    func testEmptyDiscoveryUsesOnlySavedIP() {
        let endpoints = saved(name: "Roshar").reconnectEndpoints(among: [])
        XCTAssertEqual(endpoints, [.hostPort(host: "10.0.0.5", port: 54321)])
    }

    /// A manually-entered host stores `name == IP`, which never matches a Bonjour service name,
    /// so it falls back to the saved host:port (intended — manual/off-LAN hosts have no Bonjour).
    func testManualIPNameFallsBackToSavedAddress() {
        let endpoints = saved(name: "192.168.1.5", host: "192.168.1.5")
            .reconnectEndpoints(among: [discovered("Roshar")])
        XCTAssertEqual(endpoints, [.hostPort(host: "192.168.1.5", port: 54321)])
    }

    /// Duplicate Bonjour names add only ONE discovered endpoint (first match), then the saved IP —
    /// never both. Picking the wrong same-named Mac is still pin-gated, so it can't be trusted.
    func testDuplicateDiscoveredNamesAddOnlyOneBonjourEndpoint() {
        let endpoints = saved(name: "Roshar")
            .reconnectEndpoints(among: [discovered("Roshar"), discovered("Roshar")])
        XCTAssertEqual(endpoints.count, 2)
        XCTAssertEqual(endpoints.last, .hostPort(host: "10.0.0.5", port: 54321))
    }
}

// SPDX-License-Identifier: Apache-2.0
import Network
import PortviewTransport
import XCTest

@testable import PortviewClient

/// Notification tap → saved-Mac reconnect flow selection: the tapped notification carries the
/// beacon's `recordName` (the host pin fingerprint hex), which selects the saved Mac, whose
/// `reconnectEndpoints(among:)` puts a live Bonjour re-resolve AHEAD of the possibly-stale saved
/// IP (a DHCP move after reboot is the common re-wake case).
final class ReWakeTapRoutingTests: XCTestCase {
    private let pinA = String(repeating: "a", count: 64)
    private let pinB = String(repeating: "b", count: 64)

    private func saved(name: String, pinHex: String, host: String = "10.0.0.5") -> SavedHost {
        SavedHost(name: name, host: host, port: 54321, pinHex: pinHex)
    }

    private func discovered(_ name: String) -> DiscoveredHost {
        DiscoveredHost(
            id: name, name: name,
            endpoint: .service(name: name, type: "_portview._udp", domain: "local.", interface: nil))
    }

    func testSelectsTheSavedMacTheNotificationAnnounces() {
        let hosts = [saved(name: "Roshar", pinHex: pinA), saved(name: "Scadrial", pinHex: pinB)]
        XCTAssertEqual(ReWakeTapRouting.savedHost(forPinHex: pinB, in: hosts)?.name, "Scadrial")
    }

    func testUnknownPinSelectsNothing() {
        let hosts = [saved(name: "Roshar", pinHex: pinA)]
        XCTAssertNil(ReWakeTapRouting.savedHost(forPinHex: pinB, in: hosts))
    }

    /// The full tap path: selection by pin, then the reconnect flow's endpoint ordering prefers the
    /// live Bonjour re-resolve over the saved (possibly stale) IP.
    func testTapSelectionEntersReconnectFlowPreferringBonjourReResolve() throws {
        let hosts = [saved(name: "Roshar", pinHex: pinA)]
        let selected = try XCTUnwrap(ReWakeTapRouting.savedHost(forPinHex: pinA, in: hosts))

        let endpoints = selected.reconnectEndpoints(among: [discovered("Other"), discovered("Roshar")])

        XCTAssertEqual(endpoints.first, discovered("Roshar").endpoint)
        XCTAssertEqual(endpoints.last, .hostPort(host: "10.0.0.5", port: 54321))
    }

    /// Off-network tap (Bonjour hasn't re-resolved the Mac): the flow still proceeds on the saved
    /// address alone — the re-wake never hard-requires discovery.
    func testTapWithNoDiscoveryFallsBackToSavedAddress() throws {
        let hosts = [saved(name: "Roshar", pinHex: pinA)]
        let selected = try XCTUnwrap(ReWakeTapRouting.savedHost(forPinHex: pinA, in: hosts))

        XCTAssertEqual(selected.reconnectEndpoints(among: []), [.hostPort(host: "10.0.0.5", port: 54321)])
    }
}

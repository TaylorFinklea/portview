// SPDX-License-Identifier: Apache-2.0
import Foundation
import Network
import Testing

@testable import PortviewClientCore

/// `submitCode` transitions exercised WITHOUT a live connection: the held-connection close is a
/// settable closure seam (mirroring `SessionViewModel.closeConnection` / SessionTeardownTests), and
/// the preamble's outputs (derived code, captured pin, endpoint, name, secret) are primed directly.
@MainActor
struct SASClientCoordinatorTests {
    private static let endpoint = NWEndpoint.service(
        name: "Roshar", type: "_portview._udp", domain: "local.", interface: nil)
    private static let pinHex = String(repeating: "a", count: 64)

    /// A coordinator parked as the preamble leaves it in `.awaitingCode` (minus the live connection,
    /// which a concrete `PortviewConnection` can't provide without a socket).
    private func awaitingCode() -> SASClientCoordinator {
        let coordinator = SASClientCoordinator()
        coordinator.derivedCode = "123456"
        coordinator.capturedPinHex = Self.pinHex
        coordinator.endpoint = Self.endpoint
        coordinator.name = "Roshar"
        coordinator.secret = ([1], [2], [3])
        return coordinator
    }

    @Test func matchRedialsPinnedWithCapturedCertWithoutClosingHeldConnection() {
        let coordinator = awaitingCode()
        var closes = 0
        coordinator.closeHeldConnection = { closes += 1 }
        var started: [(NWEndpoint, String, String?)] = []
        coordinator.startPinnedSession = { started.append(($0, $1, $2)) }
        var observed: [SASPairingState?] = []
        coordinator.onStateChange = { observed.append($0) }

        coordinator.submitCode("12 34 56") // non-digits are filtered before comparing

        #expect(coordinator.state == nil)
        #expect(observed == [nil]) // sheet dismisses; no intermediate flash
        // Hand-off, not teardown-close: the confirm task owns the held connection's close.
        #expect(closes == 0)
        #expect(coordinator.closeHeldConnection == nil)
        #expect(started.count == 1)
        #expect(started.first?.0 == Self.endpoint)
        #expect(started.first?.1 == Self.pinHex) // the CAPTURED cert hash pins the re-dial
        #expect(started.first?.2 == "Roshar")
        #expect(coordinator.secret == nil) // teardown zeroed the secret before the re-dial
        #expect(coordinator.derivedCode == nil)
    }

    @Test func mismatchClosesHeldConnectionZeroesSecretAndRefuses() {
        let coordinator = awaitingCode()
        var closes = 0
        coordinator.closeHeldConnection = { closes += 1 }
        var started = 0
        coordinator.startPinnedSession = { _, _, _ in started += 1 }

        coordinator.submitCode("654321")

        #expect(coordinator.state == .mismatch)
        #expect(closes == 1) // teardown closed the preamble connection on the mismatch exit
        #expect(coordinator.secret == nil)
        #expect(coordinator.derivedCode == nil)
        #expect(started == 0) // an unverified cert is never re-dialed
    }

    @Test func mismatchExpiresTheFlowSoAResubmitCannotMatch() {
        let coordinator = awaitingCode()
        coordinator.submitCode("654321")
        #expect(coordinator.state == .mismatch)

        var started = 0
        coordinator.startPinnedSession = { _, _, _ in started += 1 }
        coordinator.submitCode("123456") // the previously-correct code

        #expect(coordinator.state == .failed("Pairing expired — start again."))
        #expect(started == 0)
    }

    @Test func submitWithoutPreambleFailsExpired() {
        let coordinator = SASClientCoordinator()
        var started = 0
        coordinator.startPinnedSession = { _, _, _ in started += 1 }

        coordinator.submitCode("123456")

        #expect(coordinator.state == .failed("Pairing expired — start again."))
        #expect(started == 0)
    }

    @Test func expiredSubmitStillClosesAHeldPreambleConnection() {
        // Mid-preamble (connection held, code not yet derived) an expired-path submit must still
        // funnel through the teardown chokepoint and close the held connection.
        let coordinator = SASClientCoordinator()
        var closes = 0
        coordinator.closeHeldConnection = { closes += 1 }

        coordinator.submitCode("123456")

        #expect(coordinator.state == .failed("Pairing expired — start again."))
        #expect(closes == 1)
        #expect(coordinator.closeHeldConnection == nil)
    }
}

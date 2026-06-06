import PortviewTransport
import XCTest

@testable import PortviewClient

@MainActor
final class PairingCoordinatorTests: XCTestCase {
    func testCommitsPendingPairingOnceWhenStreamingStarts() {
        let payload = PairingPayload(
            host: "100.64.0.10",
            port: 54321,
            pinHex: String(repeating: "a", count: 64),
            name: "Mac"
        )
        let coordinator = PairingCoordinator()
        var remembered: [PairingPayload] = []

        coordinator.markPending(payload)
        coordinator.commitIfStreaming(false) { remembered.append($0) }
        coordinator.commitIfStreaming(true) { remembered.append($0) }
        coordinator.commitIfStreaming(true) { remembered.append($0) }

        XCTAssertEqual(remembered, [payload])
        XCTAssertNil(coordinator.pendingPayload)
    }
}

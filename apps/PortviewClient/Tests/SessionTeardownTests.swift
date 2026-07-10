// SPDX-License-Identifier: Apache-2.0
import XCTest

@testable import PortviewClient

/// Every session teardown must CLOSE the live transport, not just drop the reference: the
/// non-user-initiated ends (stream end, error, reconnect drop) all funnel through the same
/// unbind chokepoint as `disconnect()`, so asserting the chokepoint closes covers them all.
/// (`closeConnection` is the seam captured at bind — a concrete `PortviewClientSession` needs a
/// live socket, so tests inject the closure directly.)
@MainActor
final class SessionTeardownTests: XCTestCase {
    func testDisconnectClosesTheBoundConnectionExactlyOnce() {
        let viewModel = SessionViewModel()
        var closes = 0
        viewModel.closeConnection = { closes += 1 }

        viewModel.disconnect()
        XCTAssertEqual(closes, 1, "teardown must cancel the underlying connection")

        // The chokepoint clears the seam with the connection: a second teardown (e.g. a user
        // disconnect racing a stream end) must not double-close.
        viewModel.disconnect()
        XCTAssertEqual(closes, 1)
    }
}

import Testing
import Foundation
import Network
@testable import PortviewTransport

@Suite struct ConnectTimeoutTests {
    /// Nothing listens on 127.0.0.1:1 (tcpmux would need root), so the kernel refuses the TCP
    /// connect and `NWConnection` parks in `.waiting` — retrying, never `.ready`, never `.failed`.
    /// `awaitReady` only resumes on `.ready`/`.failed`/`.cancelled`, so without a connect deadline
    /// this wedges `connect()` forever. The outer `withTimeout` converts a pre-fix hang into a
    /// test FAILURE (TimeoutError) instead of wedging the suite.
    @Test func connectToUnreachableEndpointFailsWithinDeadline() async throws {
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 1)
        let parameters = TLSParameters.client(pinnedCertificateSHA256: Data(repeating: 0, count: 32))
        do {
            _ = try await withTimeout(.seconds(10)) {
                try await PortviewConnection.connect(to: endpoint, parameters: parameters,
                                                     timeout: .milliseconds(250))
            }
            Issue.record("connect to an unreachable endpoint unexpectedly succeeded")
        } catch is TimeoutError {
            Issue.record("connect hung past its injected deadline instead of throwing ConnectTimeoutError")
        } catch is ConnectTimeoutError {
            // Expected: the connect deadline fired and cancelled the wedged connection.
        }
    }
}

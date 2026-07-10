// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import Network
@testable import PortviewTransport

@Suite struct ListenerPortTests {
    /// Passing a preferred port binds that exact port (the basis for a stable, restart-surviving
    /// host endpoint). Discover a free port via an OS-assigned bind, release it, then re-request it.
    @Test func bindsRequestedPort() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()

        let probe = try PortviewListener(quicIdentity: identity)
        let freePort = try await withTimeout(.seconds(15)) { try await probe.start() }
        probe.cancel()

        let listener = try PortviewListener(quicIdentity: identity, port: freePort.rawValue)
        let bound = try await withTimeout(.seconds(15)) { try await listener.start() }
        defer { listener.cancel() }

        #expect(bound == freePort)
    }
}

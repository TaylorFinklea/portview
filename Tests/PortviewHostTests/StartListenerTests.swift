// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import Network
@testable import PortviewHostCore
import PortviewTransport

@Suite struct StartListenerTests {
    /// When the preferred port is already taken, the host falls back to an OS-assigned port
    /// (rather than failing to start), and reports a usable non-zero port.
    @Test func startListenerFallsBackWhenPreferredPortTaken() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()

        let occupier = try PortviewListener(quicIdentity: identity)
        let takenPort = try await occupier.start()
        defer { occupier.cancel() }

        let (listener, port) = try await HostRunner.startListener(
            identity: identity, serviceName: "Test", preferredPort: takenPort.rawValue)
        defer { listener.cancel() }

        #expect(port != 0)
        #expect(port != takenPort.rawValue)
    }

    /// A free preferred port is honored exactly.
    @Test func startListenerHonorsFreePreferredPort() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()

        let probe = try PortviewListener(quicIdentity: identity)
        let freePort = try await probe.start()
        probe.cancel()

        let (listener, port) = try await HostRunner.startListener(
            identity: identity, serviceName: "Test", preferredPort: freePort.rawValue)
        defer { listener.cancel() }

        #expect(port == freePort.rawValue)
    }
}

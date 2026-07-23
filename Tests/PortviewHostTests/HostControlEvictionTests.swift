// SPDX-License-Identifier: Apache-2.0
import Foundation
import Network
import Testing

@testable import PortviewHostCore
@testable import PortviewTransport
import PortviewProtocol

/// Legacy-session eviction (mutual-auth §4-RESOLVED; Kimi K3 + Sol han.1 review): when the rollout
/// policy tightens to `.required` (a device enrolls, or the migration window expires), sessions
/// admitted UN-authenticated under bootstrap must be terminated — a screen-control tool can't leave
/// keyboard/clipboard/file access running for a peer the host no longer trusts — while authenticated
/// sessions are spared. `PortviewConnection` wraps a live socket with no fake seam, so the two
/// registered sessions are real loopback connections; the assertion is on the deterministic
/// registry selection (which ids survive) rather than on QUIC close-propagation timing, which races
/// the tolerated server-side double-delivery.
@Suite(.timeLimit(.minutes(1))) struct HostControlEvictionTests {
    /// Two accepted host-side connections (any two — phantom-vs-real doesn't matter here, they are
    /// only registry values), from two client dials.
    private func twoHostConnections(_ listener: PortviewListener, port: NWEndpoint.Port) async throws
        -> (PortviewConnection, PortviewConnection) {
        var accepted: [PortviewConnection] = []
        let clients = try await withThrowingTaskGroup(of: PortviewConnection.self) { group -> [PortviewConnection] in
            for _ in 0..<2 {
                group.addTask {
                    let (c, _) = try await PortviewConnection.connectCapturingCert(
                        to: .hostPort(host: "127.0.0.1", port: port))
                    return c
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        for await conn in listener.connections {
            accepted.append(conn)
            if accepted.count == 2 { break }
        }
        clients.forEach { _ = $0 }  // keep the client ends alive through registration
        return (accepted[0], accepted[1])
    }

    @Test func evictLegacyRemovesLegacyKeepsAuthenticated() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let listener = try PortviewListener(quicIdentity: identity)
        let port = try await listener.start()
        defer { listener.cancel() }

        let control = HostControl(keepAwake: KeepAwake(backend: NoopKeepAwakeBackend()))
        let (connA, connB) = try await twoHostConnections(listener, port: port)
        control.register("legacy", connA, outbound: OutboundLane(connection: connA),
                         authClass: .legacyAdmitted)
        control.register("authed", connB, outbound: OutboundLane(connection: connB),
                         authClass: .authenticated)
        #expect(control.activeSessionIDs() == ["legacy", "authed"])

        control.evictLegacyAdmitted()
        // Only the authenticated session survives; the legacy one was deregistered (and its
        // connection closed) synchronously.
        #expect(control.activeSessionIDs() == ["authed"])

        // Idempotent: a second call with no legacy sessions left is a no-op.
        control.evictLegacyAdmitted()
        #expect(control.activeSessionIDs() == ["authed"])
    }
}

/// A keep-awake backend that does nothing (tests must not touch the live IOPM assertion surface —
/// see the `test-live-side-effects` memory).
private final class NoopKeepAwakeBackend: KeepAwakeBackend, @unchecked Sendable {
    func beginPreventingSleep() {}
    func endPreventingSleep() {}
    func declareUserActivity() {}
}

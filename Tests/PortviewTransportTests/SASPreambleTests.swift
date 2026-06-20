import Testing
import Foundation
import Network
@testable import PortviewTransport
@testable import PortviewProtocol

@Suite struct SASPreambleTests {
    /// Guardrail A negative test (the one the v1 review said was missing): the PRODUCTION pinned
    /// client rejects a mismatched cert. Proves the strict verify still fails closed — so wiring the
    /// capturing (TOFU) path in by accident would be caught by this going green when it shouldn't.
    @Test func pinnedClientRejectsMismatchedCert() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let listener = try PortviewListener(quicIdentity: identity)
        let port = try await withTimeout(.seconds(15)) { try await listener.start() }
        let serverTask = Task { for await _ in listener.connections {} }
        defer { serverTask.cancel(); listener.cancel() }

        let wrongPin = Data(repeating: 0xFF, count: 32)  // not the host's leaf hash
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)

        await #expect(throws: (any Error).self) {
            _ = try await withTimeout(.seconds(15)) {
                try await PortviewConnection.connectQUIC(to: endpoint, pinnedCertificateSHA256: wrongPin)
            }
        }
    }

    /// The capturing preamble connect accepts any cert (TOFU) and returns the leaf SHA-256 actually
    /// presented — which must equal the host identity's cert hash (so the later pinned re-dial pins
    /// the same entity the SAS code was derived against).
    @Test func capturingConnectReturnsPresentedLeafHash() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let expected = try identity.certificateSHA256()
        let listener = try PortviewListener(quicIdentity: identity)
        let port = try await withTimeout(.seconds(15)) { try await listener.start() }
        let serverTask = Task { for await _ in listener.connections {} }
        defer { serverTask.cancel(); listener.cancel() }

        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let (connection, captured) = try await withTimeout(.seconds(15)) {
            try await PortviewConnection.connectCapturingCert(to: endpoint)
        }
        defer { connection.close() }
        #expect(captured == expected)
    }
}

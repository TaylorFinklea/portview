// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation
import Testing

@testable import PortviewHostCore
@testable import PortviewTransport
import PortviewProtocol

/// End-to-end loopback exercise of the auth gate WIRED into the real `serveSession`: a real client
/// over a real QUIC connection. Complements AuthGateTests (which prove the gate's decision table
/// seam-driven): these prove the serveSession integration — a rejected peer is closed with NO
/// scaffolding built, an authenticated peer proceeds past the gate, and a non-hello first frame
/// closes before a challenge is even issued.
@Suite(.timeLimit(.minutes(1))) struct AuthGateSessionTests {
    private final class MemoryPairingStore: PairingRecordStore, @unchecked Sendable {
        private let lock = NSLock()
        private var blob: Data?
        func read() throws -> Data? { lock.lock(); defer { lock.unlock() }; return blob }
        func write(_ data: Data) throws { lock.lock(); defer { lock.unlock() }; blob = data }
    }

    private actor Probe {
        private(set) var outcomes: [HostRunner.AuthGateOutcome] = []
        private(set) var scaffoldingBuilds = 0
        func record(_ outcome: HostRunner.AuthGateOutcome) { outcomes.append(outcome) }
        func recordScaffolding() { scaffoldingBuilds += 1 }
    }

    /// Serve every accepted connection with the REAL serveSession (empty display registry — the
    /// gate must resolve before any display is needed), recording gate outcomes + scaffolding.
    private func runHost(_ listener: PortviewListener, hostCert: [UInt8],
                         policy: MutualAuthPolicy, pairings: PairingStore,
                         probe: Probe) -> Task<Void, Never> {
        Task {
            await withTaskGroup(of: Void.self) { group in
                for await conn in listener.connections {
                    group.addTask {
                        await HostRunner.serveSession(
                            conn, registry: DisplayRegistry([]), hostCertSHA256: hostCert,
                            authPolicy: policy, pairings: pairings,
                            onAuthGateOutcome: { o in Task { await probe.record(o) } },
                            didBuildScaffolding: { Task { await probe.recordScaffolding() } })
                    }
                }
            }
        }
    }

    private func hello() -> AnyMessage {
        .clientHello(ClientHello(protocolVersion: 1, deviceID: "t", deviceName: "t", codecs: [.hevc]))
    }

    private func awaitOutcome(_ probe: Probe) async -> HostRunner.AuthGateOutcome? {
        for _ in 0..<500 {
            if let outcome = await probe.outcomes.first { return outcome }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    @Test func unauthorizedClientAuthClosesWithNoScaffolding() async throws {
        // The bead's named check: a valid-signature auth from an UN-ENROLLED key is rejected and
        // the connection closes with NO scaffolding built.
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let hostCert = [UInt8](try identity.certificateSHA256())
        let listener = try PortviewListener(quicIdentity: identity)
        let port = try await listener.start()
        let pairings = PairingStore(store: MemoryPairingStore())  // nobody enrolled
        let probe = Probe()
        let host = runHost(listener, hostCert: hostCert, policy: .required, pairings: pairings, probe: probe)
        defer { host.cancel(); listener.cancel() }

        let (conn, captured) = try await PortviewConnection.connectCapturingCert(
            to: .hostPort(host: "127.0.0.1", port: port))
        defer { conn.close() }
        try await conn.send(hello())

        var it = conn.inbound.makeAsyncIterator()
        guard case .serverChallenge(let challenge)? = await it.next() else {
            Issue.record("expected ServerChallenge after ClientHello"); return
        }
        let key = Curve25519.Signing.PrivateKey()
        let signature = try ClientAuthCrypto.sign(
            privateKey: key, nonce: challenge.nonce, hostCertSHA256: [UInt8](captured))
        try await conn.send(.clientAuth(ClientAuth(
            publicKey: Array(key.publicKey.rawRepresentation), signature: signature)))

        // The host closes: the client's inbound ends with no ServerHello.
        while let message = await it.next() {
            if case .serverHello = message { Issue.record("rejected peer must never see ServerHello") }
        }
        #expect(await awaitOutcome(probe) == .rejected(.unknownKey))
        #expect(await probe.scaffoldingBuilds == 0)
    }

    @Test func enrolledClientAuthenticatesPastTheGate() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let hostCert = [UInt8](try identity.certificateSHA256())
        let listener = try PortviewListener(quicIdentity: identity)
        let port = try await listener.start()
        let key = Curve25519.Signing.PrivateKey()
        let pairings = PairingStore(store: MemoryPairingStore())
        try await pairings.enroll(publicKey: key.publicKey.rawRepresentation, deviceName: "phone")
        let expectedID = PairingStore.deviceID(forPublicKey: key.publicKey.rawRepresentation)
        let probe = Probe()
        let host = runHost(listener, hostCert: hostCert, policy: .required, pairings: pairings, probe: probe)
        defer { host.cancel(); listener.cancel() }

        let (conn, captured) = try await PortviewConnection.connectCapturingCert(
            to: .hostPort(host: "127.0.0.1", port: port))
        defer { conn.close() }
        try await conn.send(hello())

        var it = conn.inbound.makeAsyncIterator()
        guard case .serverChallenge(let challenge)? = await it.next() else {
            Issue.record("expected ServerChallenge after ClientHello"); return
        }
        let signature = try ClientAuthCrypto.sign(
            privateKey: key, nonce: challenge.nonce, hostCertSHA256: [UInt8](captured))
        try await conn.send(.clientAuth(ClientAuth(
            publicKey: Array(key.publicKey.rawRepresentation), signature: signature)))

        // Gate wiring proof: the outcome is authenticated with the enrolled id. (The empty test
        // registry then ends the session at the display guard — scaffolding is display-gated.)
        #expect(await awaitOutcome(probe) == .authenticated(deviceID: expectedID))
    }

    @Test func nonHelloFirstFrameClosesWithoutAChallenge() async throws {
        // Spec §4-RESOLVED: the first frame must be exactly SASClientCommit or ClientHello;
        // anything else closes — before a challenge, before the gate, before anything.
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let hostCert = [UInt8](try identity.certificateSHA256())
        let listener = try PortviewListener(quicIdentity: identity)
        let port = try await listener.start()
        let pairings = PairingStore(store: MemoryPairingStore())
        let probe = Probe()
        let host = runHost(listener, hostCert: hostCert, policy: .required, pairings: pairings, probe: probe)
        defer { host.cancel(); listener.cancel() }

        let (conn, _) = try await PortviewConnection.connectCapturingCert(
            to: .hostPort(host: "127.0.0.1", port: port))
        defer { conn.close() }
        try await conn.send(.ping(Ping(sendMicros: 1)))

        var it = conn.inbound.makeAsyncIterator()
        while let message = await it.next() {
            if case .serverChallenge = message { Issue.record("no challenge for a role-violating peer") }
        }
        #expect(await probe.outcomes.isEmpty)  // the gate never ran
        #expect(await probe.scaffoldingBuilds == 0)
    }
}

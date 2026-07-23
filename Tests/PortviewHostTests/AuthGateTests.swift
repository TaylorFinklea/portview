// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation
import Testing

@testable import PortviewHostCore
@testable import PortviewTransport
import PortviewProtocol

/// The mutual-auth streaming gate (`HostRunner.serveAuthGate`, spec §3 + §4-RESOLVED): after the
/// host issues its challenge, exactly one valid, enrolled `ClientAuth` proceeds; everything else
/// fails closed — except a SILENT client under an active legacy-bootstrap policy, which is
/// admitted as a warned legacy session. Pure seam-driven tests: the inbound is a hand-fed
/// stream, the outbound is a recording closure — no sockets.
@Suite struct AuthGateTests {
    private enum TestStoreError: Error { case injected }

    private final class MemoryPairingStore: PairingRecordStore, @unchecked Sendable {
        private let lock = NSLock()
        private var blob: Data?
        func read() throws -> Data? { lock.lock(); defer { lock.unlock() }; return blob }
        func write(_ data: Data) throws { lock.lock(); defer { lock.unlock() }; blob = data }
    }

    /// One scripted gate run: `respond` maps the issued challenge to the client's scripted reply
    /// messages (empty = a silent/legacy client). Returns the outcome.
    private func runGate(
        mode: MutualAuthPolicy.Mode,
        pairings: PairingStore,
        hostCertSHA256: [UInt8] = [UInt8](repeating: 0x3C, count: 32),
        deadline: Duration = .seconds(2),
        respond: @escaping @Sendable (ServerChallenge) -> [AnyMessage]
    ) async -> HostRunner.AuthGateOutcome {
        let (stream, continuation) = AsyncStream.makeStream(of: AnyMessage.self)
        let inbound = HostRunner.MessageReader(stream)
        return await HostRunner.serveAuthGate(
            inbound: inbound, hostCertSHA256: hostCertSHA256, mode: mode,
            pairings: pairings, deadline: deadline,
            sendChallenge: { challenge in
                for message in respond(challenge) { continuation.yield(message) }
            })
    }

    private static let certHash = [UInt8](repeating: 0x3C, count: 32)

    private func auth(for key: Curve25519.Signing.PrivateKey, challenge: ServerChallenge,
                      certHash: [UInt8] = AuthGateTests.certHash) -> AnyMessage {
        let signature = try! ClientAuthCrypto.sign(
            privateKey: key, nonce: challenge.nonce, hostCertSHA256: certHash)
        return .clientAuth(ClientAuth(
            publicKey: Array(key.publicKey.rawRepresentation), signature: signature))
    }

    @Test func enrolledKeyWithValidSignatureAuthenticates() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let pairings = PairingStore(store: MemoryPairingStore())
        try await pairings.enroll(publicKey: key.publicKey.rawRepresentation, deviceName: "phone")
        let expectedID = PairingStore.deviceID(forPublicKey: key.publicKey.rawRepresentation)

        let outcome = await runGate(mode: .required, pairings: pairings) { challenge in
            [self.auth(for: key, challenge: challenge)]
        }
        #expect(outcome == .authenticated(deviceID: expectedID))
    }

    @Test func forgedSignatureIsRejected() async throws {
        // Signature over the WRONG nonce (a replayed prior challenge) must fail closed even for
        // an enrolled key — the fresh-nonce binding is the replay defense.
        let key = Curve25519.Signing.PrivateKey()
        let pairings = PairingStore(store: MemoryPairingStore())
        try await pairings.enroll(publicKey: key.publicKey.rawRepresentation, deviceName: "phone")

        let outcome = await runGate(mode: .required, pairings: pairings) { _ in
            let stale = ServerChallenge(nonce: [UInt8](repeating: 0xEE, count: 32))
            return [self.auth(for: key, challenge: stale)]
        }
        #expect(outcome == .rejected(.invalidSignature))
    }

    @Test func forgedSignatureIsRejectedUnderBootstrapToo() async throws {
        // Decision-table pin (Kimi K3 han.1 review): an INVALID signature rejects in BOTH modes —
        // bootstrap's legacy admittance is only for peers that never speak; a peer that presents
        // bad crypto must never fall through to legacy admission.
        let key = Curve25519.Signing.PrivateKey()
        let pairings = PairingStore(store: MemoryPairingStore())
        try await pairings.enroll(publicKey: key.publicKey.rawRepresentation, deviceName: "phone")

        let outcome = await runGate(mode: .bootstrap, pairings: pairings) { _ in
            let stale = ServerChallenge(nonce: [UInt8](repeating: 0xEE, count: 32))
            return [self.auth(for: key, challenge: stale)]
        }
        #expect(outcome == .rejected(.invalidSignature))
    }

    @Test func validSignatureFromUnknownKeyIsRejected() async throws {
        // Possession alone is not authorization: an un-enrolled key fails closed. (han.3 turns
        // exactly this case — valid sig, unknown key, open pairing window — into the enrollment
        // prompt; until then it must close.)
        let key = Curve25519.Signing.PrivateKey()
        let pairings = PairingStore(store: MemoryPairingStore())  // nobody enrolled

        let outcome = await runGate(mode: .required, pairings: pairings) { challenge in
            [self.auth(for: key, challenge: challenge)]
        }
        #expect(outcome == .rejected(.unknownKey))
    }

    @Test func silentClientIsLegacyAdmittedUnderBootstrap() async throws {
        // A pre-auth client skips the unknown challenge tag and sends nothing — under an ACTIVE
        // bootstrap policy it is admitted as a warned legacy session after the deadline.
        let pairings = PairingStore(store: MemoryPairingStore())
        let outcome = await runGate(
            mode: .bootstrap, pairings: pairings, deadline: .milliseconds(100)) { _ in [] }
        #expect(outcome == .legacyAdmitted)
    }

    @Test func silentClientIsRejectedUnderRequired() async throws {
        let pairings = PairingStore(store: MemoryPairingStore())
        let outcome = await runGate(
            mode: .required, pairings: pairings, deadline: .milliseconds(100)) { _ in [] }
        #expect(outcome == .rejected(.timeout))
    }

    @Test func unexpectedMessageDuringGateIsRejected() async throws {
        // The gate accepts exactly one ClientAuth (plus tolerated duplicate hellos) — anything
        // else is a protocol violation and closes, even under bootstrap: a live message that
        // isn't auth means the peer is NOT a silent legacy client.
        let pairings = PairingStore(store: MemoryPairingStore())
        let outcome = await runGate(mode: .bootstrap, pairings: pairings) { _ in
            [.ping(Ping(sendMicros: 1))]
        }
        #expect(outcome == .rejected(.unexpectedMessage))
    }

    @Test func strayMessageBeforeAuthIsRejectedNotRetried() async throws {
        // The gate reads exactly ONE message under a single deadline (Sol han.1 review, MEDIUM):
        // the initial ClientHello is already consumed before the gate, so a further message that
        // isn't ClientAuth — a stray/duplicate hello included — is a protocol violation, and the
        // gate must NOT grant it a fresh deadline (the starvation vector). It rejects even though a
        // valid auth follows in the stream.
        let key = Curve25519.Signing.PrivateKey()
        let pairings = PairingStore(store: MemoryPairingStore())
        try await pairings.enroll(publicKey: key.publicKey.rawRepresentation, deviceName: "phone")

        let hello = AnyMessage.clientHello(ClientHello(
            protocolVersion: 1, deviceID: "dup", deviceName: "dup", codecs: [.hevc]))
        let outcome = await runGate(mode: .required, pairings: pairings) { challenge in
            [hello, self.auth(for: key, challenge: challenge)]
        }
        #expect(outcome == .rejected(.unexpectedMessage))
    }

    @Test func missingHostCertHashFailsClosedBeforeChallenging() async throws {
        // Spec must-fix: auth binding fails closed if the 32-byte host cert hash is unavailable —
        // an empty hash would let the relay-defense field be silently omitted. No challenge is
        // even issued.
        let key = Curve25519.Signing.PrivateKey()
        let pairings = PairingStore(store: MemoryPairingStore())
        try await pairings.enroll(publicKey: key.publicKey.rawRepresentation, deviceName: "phone")

        let outcome = await runGate(mode: .required, pairings: pairings, hostCertSHA256: []) { _ in
            Issue.record("challenge must not be issued without a bindable host cert hash")
            return []
        }
        _ = key
        #expect(outcome == .rejected(.missingHostCertHash))
    }
}

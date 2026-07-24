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

    /// Thread-safe mutable Bool for driving a TOCTOU race: a test flips it mid-gate-wait to prove
    /// the gate re-reads window state at the decision point rather than trusting a stale snapshot.
    private final class LockingBoolBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ value: Bool) { self.value = value }
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: Bool) { lock.lock(); defer { lock.unlock() }; value = newValue }
    }

    /// Thread-safe mutable `MutualAuthPolicy.Mode` for driving a Finding-A TOCTOU race: a test
    /// flips it mid-gate-wait to prove the gate re-reads the ACTIVE mode at the decision point
    /// (via `effectiveMode`) rather than trusting a mode sampled once before the wait began.
    private final class LockingModeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: MutualAuthPolicy.Mode
        init(_ value: MutualAuthPolicy.Mode) { self.value = value }
        func get() -> MutualAuthPolicy.Mode { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: MutualAuthPolicy.Mode) { lock.lock(); defer { lock.unlock() }; value = newValue }
    }

    /// One scripted gate run: `respond` maps the issued challenge to the client's scripted reply
    /// messages (empty = a silent/legacy client). `effectiveMode` is evaluated AT the gate's
    /// timeout decision point (Finding A), never sampled once at entry — tests that don't care
    /// about a mid-wait mode change pass a fixed-value closure (`{ .bootstrap }` / `{ .required }`).
    private func runGate(
        effectiveMode: @escaping @Sendable () async -> MutualAuthPolicy.Mode,
        pairings: PairingStore,
        hostCertSHA256: [UInt8] = [UInt8](repeating: 0x3C, count: 32),
        deadline: Duration = .seconds(2),
        isSASWindowOpen: @escaping @Sendable () async -> Bool = { false },
        respond: @escaping @Sendable (ServerChallenge) -> [AnyMessage]
    ) async -> HostRunner.AuthGateOutcome {
        let (stream, continuation) = AsyncStream.makeStream(of: AnyMessage.self)
        let inbound = HostRunner.MessageReader(stream)
        return await HostRunner.serveAuthGate(
            inbound: inbound, hostCertSHA256: hostCertSHA256, effectiveMode: effectiveMode,
            isSASWindowOpen: isSASWindowOpen, pairings: pairings, deadline: deadline,
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

        let outcome = await runGate(effectiveMode: { .required }, pairings: pairings) { challenge in
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

        let outcome = await runGate(effectiveMode: { .required }, pairings: pairings) { _ in
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

        let outcome = await runGate(effectiveMode: { .bootstrap }, pairings: pairings) { _ in
            let stale = ServerChallenge(nonce: [UInt8](repeating: 0xEE, count: 32))
            return [self.auth(for: key, challenge: stale)]
        }
        #expect(outcome == .rejected(.invalidSignature))
    }

    @Test func validSignatureFromUnknownKeyReturnsKeySnapshot() async throws {
        // Possession alone is not authorization: an un-enrolled key does not authenticate. Instead
        // of failing closed outright, the gate now hands back a snapshot of the (validly-signed,
        // unenrolled) key — the han.3 enrollment-ceremony hook (spec §4-RESOLVED must-fix 1). Task
        // 6 wires the ceremony; until then the caller closes on this outcome exactly as it did on
        // the old `.rejected(.unknownKey)`.
        let key = Curve25519.Signing.PrivateKey()
        let pairings = PairingStore(store: MemoryPairingStore())  // nobody enrolled

        let outcome = await runGate(effectiveMode: { .required }, pairings: pairings) { challenge in
            [self.auth(for: key, challenge: challenge)]
        }
        #expect(outcome == .unknownKey(publicKey: Array(key.publicKey.rawRepresentation)))
    }

    @Test func silentClientIsLegacyAdmittedUnderBootstrap() async throws {
        // A pre-auth client skips the unknown challenge tag and sends nothing — under an ACTIVE
        // bootstrap policy, with NO pairing window open, it is admitted as a warned legacy session
        // after the deadline.
        let pairings = PairingStore(store: MemoryPairingStore())
        let outcome = await runGate(
            effectiveMode: { .bootstrap }, pairings: pairings, deadline: .milliseconds(100),
            isSASWindowOpen: { false }) { _ in [] }
        #expect(outcome == .legacyAdmitted)
    }

    @Test func silentPeerUnderBootstrapWithWindowOpenIsClosed() async throws {
        // Legacy barrier (design v2 H3): no legacy admissions while the ceremony window is open —
        // a legacy peer could watch the screen and click Deny. A silent peer under `.bootstrap`
        // WITH the pairing window open must close, not legacy-admit.
        let pairings = PairingStore(store: MemoryPairingStore())
        let outcome = await runGate(
            effectiveMode: { .bootstrap }, pairings: pairings, deadline: .milliseconds(100),
            isSASWindowOpen: { true }) { _ in [] }
        #expect(outcome == .rejected(.timeout))
    }

    @Test func windowOpenedDuringGateWaitIsCaughtAtDecisionTime() async throws {
        // TOCTOU regression (review finding): sampling the pairing-window state ONCE before the
        // gate's wait let a silent peer already in-flight when the user opens the pairing window
        // resolve against a STALE `false` → `.legacyAdmitted` during an active ceremony — exactly
        // the scenario the barrier exists to prevent, and the window-open evict sweep can't catch
        // it (the admission registers after the sweep). The gate must re-evaluate window state AT
        // the timeout decision point: a window that opens mid-wait must still be caught.
        let box = LockingBoolBox(false)
        let pairings = PairingStore(store: MemoryPairingStore())
        async let outcome = runGate(
            effectiveMode: { .bootstrap }, pairings: pairings, deadline: .milliseconds(100),
            isSASWindowOpen: { box.get() }) { _ in [] }
        try await Task.sleep(for: .milliseconds(30))
        box.set(true)
        let result = await outcome
        #expect(result == .rejected(.timeout))
    }

    @Test func staleModeAtEntryDoesNotBypassPromotionDuringGateWait() async throws {
        // Finding A (CRITICAL): the gate must re-evaluate the ACTIVE policy mode AT the timeout
        // decision point, not trust a `.bootstrap` mode sampled once before the wait began —
        // mirroring the `isSASWindowOpen` TOCTOU fix above. A silent peer already in-flight when a
        // first enrollment promotes the store to `.required` mid-wait (window closed) must be
        // rejected, never legacy-admitted against the stale snapshot.
        let box = LockingModeBox(.bootstrap)
        let pairings = PairingStore(store: MemoryPairingStore())
        async let outcome = runGate(
            effectiveMode: { box.get() }, pairings: pairings, deadline: .milliseconds(100),
            isSASWindowOpen: { false }) { _ in [] }
        try await Task.sleep(for: .milliseconds(30))
        box.set(.required)
        let result = await outcome
        #expect(result == .rejected(.timeout))
    }

    @Test func silentClientIsRejectedUnderRequired() async throws {
        let pairings = PairingStore(store: MemoryPairingStore())
        let outcome = await runGate(
            effectiveMode: { .required }, pairings: pairings, deadline: .milliseconds(100)) { _ in [] }
        #expect(outcome == .rejected(.timeout))
    }

    @Test func unexpectedMessageDuringGateIsRejected() async throws {
        // The gate accepts exactly one ClientAuth (plus tolerated duplicate hellos) — anything
        // else is a protocol violation and closes, even under bootstrap: a live message that
        // isn't auth means the peer is NOT a silent legacy client.
        let pairings = PairingStore(store: MemoryPairingStore())
        let outcome = await runGate(effectiveMode: { .bootstrap }, pairings: pairings) { _ in
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
        let outcome = await runGate(effectiveMode: { .required }, pairings: pairings) { challenge in
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

        let outcome = await runGate(effectiveMode: { .required }, pairings: pairings, hostCertSHA256: []) { _ in
            Issue.record("challenge must not be issued without a bindable host cert hash")
            return []
        }
        _ = key
        #expect(outcome == .rejected(.missingHostCertHash))
    }
}

// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import CryptoKit
@testable import PortviewProtocol

/// The mutual-auth signed-challenge crypto (spec §3). Replay defense = the nonce; relay/MITM
/// defense = binding the host cert hash into the signed payload. Both must be verified against a
/// frozen payload framing so the wire contract can't drift.
@Suite struct ClientAuthCryptoTests {
    private func nonce(_ b: UInt8) -> [UInt8] { [UInt8](repeating: b, count: 32) }
    private func certHash(_ b: UInt8) -> [UInt8] { [UInt8](repeating: b, count: 32) }

    @Test func signedPayloadIsFrozen() {
        // The exact bytes signed: UTF8("Portview client-auth v1") ‖ nonce[32] ‖ hostCertSHA256[32].
        let payload = ClientAuthCrypto.signedPayload(nonce: nonce(0x01), hostCertSHA256: certHash(0x02))
        let expected = Array("Portview client-auth v1".utf8)
            + [UInt8](repeating: 0x01, count: 32)
            + [UInt8](repeating: 0x02, count: 32)
        #expect(payload == expected)
        #expect(payload.count == 23 + 32 + 32)
    }

    @Test func signVerifyRoundTrips() throws {
        let priv = Curve25519.Signing.PrivateKey()
        let pub = Array(priv.publicKey.rawRepresentation)
        let n = nonce(0x11), h = certHash(0x22)
        let sig = try ClientAuthCrypto.sign(privateKey: priv, nonce: n, hostCertSHA256: h)
        #expect(ClientAuthCrypto.verify(publicKey: pub, signature: sig, nonce: n, hostCertSHA256: h))
    }

    @Test func verifyFailsForReplayedNonce() throws {
        // A signature over one challenge must not verify against a different (fresh) challenge.
        let priv = Curve25519.Signing.PrivateKey()
        let pub = Array(priv.publicKey.rawRepresentation)
        let h = certHash(0x22)
        let sig = try ClientAuthCrypto.sign(privateKey: priv, nonce: nonce(0x11), hostCertSHA256: h)
        #expect(ClientAuthCrypto.verify(publicKey: pub, signature: sig, nonce: nonce(0x99), hostCertSHA256: h) == false)
    }

    @Test func verifyFailsForRelayedHostCertHash() throws {
        // The relay defense: a signature bound to the real host's cert hash must not verify under a
        // different (MITM) cert hash.
        let priv = Curve25519.Signing.PrivateKey()
        let pub = Array(priv.publicKey.rawRepresentation)
        let n = nonce(0x11)
        let sig = try ClientAuthCrypto.sign(privateKey: priv, nonce: n, hostCertSHA256: certHash(0x22))
        #expect(ClientAuthCrypto.verify(publicKey: pub, signature: sig, nonce: n, hostCertSHA256: certHash(0x33)) == false)
    }

    @Test func verifyFailsForWrongPublicKey() throws {
        let priv = Curve25519.Signing.PrivateKey()
        let other = Curve25519.Signing.PrivateKey()
        let n = nonce(0x11), h = certHash(0x22)
        let sig = try ClientAuthCrypto.sign(privateKey: priv, nonce: n, hostCertSHA256: h)
        #expect(ClientAuthCrypto.verify(publicKey: Array(other.publicKey.rawRepresentation),
                                        signature: sig, nonce: n, hostCertSHA256: h) == false)
    }

    @Test func verifyFailsForTamperedSignature() throws {
        let priv = Curve25519.Signing.PrivateKey()
        let pub = Array(priv.publicKey.rawRepresentation)
        let n = nonce(0x11), h = certHash(0x22)
        var sig = try ClientAuthCrypto.sign(privateKey: priv, nonce: n, hostCertSHA256: h)
        sig[0] ^= 0xFF
        #expect(ClientAuthCrypto.verify(publicKey: pub, signature: sig, nonce: n, hostCertSHA256: h) == false)
    }

    @Test func verifyFailsClosedForMalformedPublicKey() {
        // A garbage/short public key must return false, never throw on the accept path.
        #expect(ClientAuthCrypto.verify(publicKey: [0x00, 0x01], signature: [UInt8](repeating: 0, count: 64),
                                        nonce: nonce(0x11), hostCertSHA256: certHash(0x22)) == false)
    }
}

/// Wire round-trip + strict-framing for the two new handshake messages (wire-safety gates
/// complement `GoldenFrameTests`).
@Suite struct HandshakeMessageWireTests {
    @Test func serverChallengeRoundTrips() throws {
        let m = ServerChallenge(nonce: (0..<32).map { UInt8($0) })
        #expect(try Frame.decode(Frame.encodeAny(.serverChallenge(m))) == .serverChallenge(m))
    }

    @Test func clientAuthRoundTrips() throws {
        let m = ClientAuth(publicKey: (0..<32).map { UInt8($0) },
                           signature: (0..<64).map { UInt8($0) })
        #expect(try Frame.decode(Frame.encodeAny(.clientAuth(m))) == .clientAuth(m))
    }

    @Test func serverChallengeRejectsTrailingBytes() {
        // A 33-byte payload (one trailing byte past the 32-byte nonce) must be rejected, not
        // silently accepted — the framing is fixed-width.
        let frame: [UInt8] = [34, 31] + [UInt8](repeating: 0xAA, count: 33)
        #expect(throws: (any Error).self) { try Frame.decode(frame) }
    }

    @Test func clientAuthRejectsTrailingBytes() {
        let frame: [UInt8] = [98, 32] + [UInt8](repeating: 0xBB, count: 32) + [UInt8](repeating: 0xCC, count: 65)
        #expect(throws: (any Error).self) { try Frame.decode(frame) }
    }

    @Test func clientAuthRejectsTruncatedPayload() {
        // Only the key, no signature.
        let frame: [UInt8] = [33, 32] + [UInt8](repeating: 0xBB, count: 32)
        #expect(throws: (any Error).self) { try Frame.decode(frame) }
    }
}

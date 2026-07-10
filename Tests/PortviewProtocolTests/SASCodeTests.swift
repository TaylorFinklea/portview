// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import PortviewProtocol

@Suite struct SASCodeTests {
    // Fixed vectors for determinism + the frozen known-answer test.
    let clientNonce = Array<UInt8>(0..<16)
    let hostNonce = Array<UInt8>(16..<32)
    let certA = Array<UInt8>(repeating: 0xAB, count: 32)
    let certB = Array<UInt8>(repeating: 0xCD, count: 32)

    // MARK: derive

    @Test func deriveIsDeterministic() {
        let a = SASCode.derive(clientNonce: clientNonce, hostNonce: hostNonce, certSHA256: certA)
        let b = SASCode.derive(clientNonce: clientNonce, hostNonce: hostNonce, certSHA256: certA)
        #expect(a == b)
    }

    @Test func deriveIsAlwaysSixDigits() {
        // Sweep nonces; every code is exactly 6 ASCII digits (covers leading-zero zero-padding).
        for i in 0..<64 {
            let cn = Array<UInt8>(repeating: UInt8(i), count: 16)
            let hn = Array<UInt8>(repeating: UInt8(63 - i), count: 16)
            let code = SASCode.derive(clientNonce: cn, hostNonce: hn, certSHA256: certA)
            #expect(code.count == 6)
            #expect(code.allSatisfy { $0.isNumber })
        }
    }

    @Test func deriveBindsToCert() {
        // The MITM-defeat invariant: a different leaf cert yields a different code.
        let a = SASCode.derive(clientNonce: clientNonce, hostNonce: hostNonce, certSHA256: certA)
        let b = SASCode.derive(clientNonce: clientNonce, hostNonce: hostNonce, certSHA256: certB)
        #expect(a != b)
    }

    @Test func deriveIsNonceSensitive() {
        var cn = clientNonce; cn[0] ^= 0x01
        let base = SASCode.derive(clientNonce: clientNonce, hostNonce: hostNonce, certSHA256: certA)
        let flippedClient = SASCode.derive(clientNonce: cn, hostNonce: hostNonce, certSHA256: certA)
        var hn = hostNonce; hn[15] ^= 0x80
        let flippedHost = SASCode.derive(clientNonce: clientNonce, hostNonce: hn, certSHA256: certA)
        #expect(base != flippedClient)
        #expect(base != flippedHost)
    }

    @Test func deriveKnownAnswerVector() {
        // Frozen wire contract: clientNonce=0x00..0x0F, hostNonce=0x10..0x1F, cert=32×0xAB.
        // Pins IKM order, raw-byte salt, info "Portview SAS v2", L=8, big-endian, %1e6, %06d.
        let code = SASCode.derive(clientNonce: clientNonce, hostNonce: hostNonce, certSHA256: certA)
        #expect(code == "470719")
    }

    // MARK: commit / verify

    @Test func commitIsDeterministicAndOpens() {
        let c = SASCode.commit(nonce: clientNonce, role: .client, certSHA256: certA)
        #expect(c.count == 32)
        #expect(SASCode.commit(nonce: clientNonce, role: .client, certSHA256: certA) == c)
        #expect(SASCode.verify(commitment: c, nonce: clientNonce, role: .client, certSHA256: certA))
    }

    @Test func commitRejectsWrongNonceRoleOrCert() {
        let c = SASCode.commit(nonce: clientNonce, role: .client, certSHA256: certA)
        var wrongNonce = clientNonce; wrongNonce[0] ^= 0x01
        #expect(!SASCode.verify(commitment: c, nonce: wrongNonce, role: .client, certSHA256: certA))
        #expect(!SASCode.verify(commitment: c, nonce: clientNonce, role: .host, certSHA256: certA))   // reflection defense
        #expect(!SASCode.verify(commitment: c, nonce: clientNonce, role: .client, certSHA256: certB))  // leg-swap defense
    }

    @Test func clientAndHostCommitsDifferForSameNonce() {
        // Role binding: the same nonce under client vs host roles must not collide.
        let asClient = SASCode.commit(nonce: clientNonce, role: .client, certSHA256: certA)
        let asHost = SASCode.commit(nonce: clientNonce, role: .host, certSHA256: certA)
        #expect(asClient != asHost)
    }

    @Test func randomNonceIsFreshAndCorrectLength() {
        let a = SASCode.randomNonce()
        let b = SASCode.randomNonce()
        #expect(a.count == SASCode.nonceLength)
        #expect(a != b)  // overwhelmingly likely; guards a constant/empty-nonce regression
    }

    // MARK: confirmation MAC (Guardrail E)

    @Test func confirmationIsDeterministicAndVerifies() {
        let mac = SASCode.confirmation(clientNonce: clientNonce, hostNonce: hostNonce, certSHA256: certA)
        #expect(mac.count == 32)
        #expect(SASCode.confirmation(clientNonce: clientNonce, hostNonce: hostNonce, certSHA256: certA) == mac)
        #expect(SASCode.verifyConfirmation(mac, clientNonce: clientNonce, hostNonce: hostNonce, certSHA256: certA))
    }

    @Test func confirmationKnownAnswerVector() {
        // Frozen contract for the confirm MAC (key IKM n_c‖n_h, raw-byte cert salt, info + message).
        let mac = SASCode.confirmation(clientNonce: clientNonce, hostNonce: hostNonce, certSHA256: certA)
        #expect(mac.map { String(format: "%02x", $0) }.joined() == "4338ee3cfcb3f4e2172e993e106d9a2ba7b06c92a526d3cefd77848ee19241a1")
    }

    @Test func confirmationBindsCertAndNonces() {
        let base = SASCode.confirmation(clientNonce: clientNonce, hostNonce: hostNonce, certSHA256: certA)
        #expect(base != SASCode.confirmation(clientNonce: clientNonce, hostNonce: hostNonce, certSHA256: certB))
        var cn = clientNonce; cn[0] ^= 0x01
        #expect(base != SASCode.confirmation(clientNonce: cn, hostNonce: hostNonce, certSHA256: certA))
        var hn = hostNonce; hn[0] ^= 0x01
        #expect(base != SASCode.confirmation(clientNonce: clientNonce, hostNonce: hn, certSHA256: certA))
    }

    @Test func verifyRejectsLastByteFlipAndCrossAttemptReplay() {
        var mac = SASCode.confirmation(clientNonce: clientNonce, hostNonce: hostNonce, certSHA256: certA)
        mac[mac.count - 1] ^= 0x01  // flip the last byte (catches a non-constant-time short-circuit)
        #expect(!SASCode.verifyConfirmation(mac, clientNonce: clientNonce, hostNonce: hostNonce, certSHA256: certA))
        // A MAC from attempt A must fail under attempt B's host nonce (fresh nonces are load-bearing).
        let macA = SASCode.confirmation(clientNonce: clientNonce, hostNonce: hostNonce, certSHA256: certA)
        let hostNonceB = Array<UInt8>(32..<48)
        #expect(!SASCode.verifyConfirmation(macA, clientNonce: clientNonce, hostNonce: hostNonceB, certSHA256: certA))
    }

    @Test func confirmInfoStringDiffersFromCommitAndDerive() {
        // Domain separation guard: all three SAS domain strings must differ (commit hash, code HKDF
        // info, confirm-key HKDF info) so keys/tags can't collide across the sub-protocols.
        let tags = Set([SASCode.commitTag, SASCode.deriveInfo, SASCode.confirmInfo])
        #expect(tags.count == 3)
    }

    // MARK: wire round-trips (tags 20–23)

    @Test func sasMessagesRoundTripThroughFrame() throws {
        let commit = Array<UInt8>(repeating: 0x5A, count: 32)
        let nonce = Array<UInt8>(repeating: 0x3C, count: 16)
        let messages: [AnyMessage] = [
            .sasClientCommit(SASClientCommit(commit: commit)),
            .sasHostCommit(SASHostCommit(commit: commit)),
            .sasClientReveal(SASClientReveal(nonce: nonce)),
            .sasHostReveal(SASHostReveal(nonce: nonce)),
            .sasClientConfirm(SASClientConfirm(mac: commit)),
        ]
        for any in messages {
            #expect(try Frame.decode(Frame.encodeAny(any)) == any)
        }
    }

    @Test func sasMessageTypeTags() {
        #expect(SASClientCommit.messageType == .sasClientCommit)
        #expect(SASHostCommit.messageType == .sasHostCommit)
        #expect(SASClientReveal.messageType == .sasClientReveal)
        #expect(SASHostReveal.messageType == .sasHostReveal)
        #expect(SASClientConfirm.messageType == .sasClientConfirm)
        #expect(MessageType.sasClientCommit.rawValue == 20)
        #expect(MessageType.sasHostReveal.rawValue == 23)
        #expect(MessageType.sasClientConfirm.rawValue == 24)
    }
}

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

    // MARK: wire round-trips (tags 20–23)

    @Test func sasMessagesRoundTripThroughFrame() throws {
        let commit = Array<UInt8>(repeating: 0x5A, count: 32)
        let nonce = Array<UInt8>(repeating: 0x3C, count: 16)
        let messages: [AnyMessage] = [
            .sasClientCommit(SASClientCommit(commit: commit)),
            .sasHostCommit(SASHostCommit(commit: commit)),
            .sasClientReveal(SASClientReveal(nonce: nonce)),
            .sasHostReveal(SASHostReveal(nonce: nonce)),
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
        #expect(MessageType.sasClientCommit.rawValue == 20)
        #expect(MessageType.sasHostReveal.rawValue == 23)
    }
}

// SPDX-License-Identifier: Apache-2.0
import Foundation
import PortviewProtocol
import Testing

@testable import PortviewClientCore

struct ChallengeResponseTests {
    /// Minimal in-memory `ClientIdentityStore` — mirrors `ClientIdentityTests.MemoryStore`.
    private final class MemoryStore: ClientIdentityStore, @unchecked Sendable {
        private var blob: Data?
        init(_ blob: Data? = nil) { self.blob = blob }
        func read() throws -> Data? { blob }
        func write(_ data: Data) throws { blob = data }
    }

    @Test func makeRoundTripsThroughClientAuthCryptoVerify() throws {
        let identity = try ClientIdentity.loadOrCreate(store: MemoryStore())
        let nonce = [UInt8](repeating: 0x11, count: 32)
        let pin = Data(repeating: 0x22, count: 32)
        let auth = ChallengeResponse.make(
            identity: identity, challenge: ServerChallenge(nonce: nonce), pinnedCertSHA256: pin)
        let response = try #require(auth)
        #expect(response.publicKey == Array(identity.publicKey))
        #expect(ClientAuthCrypto.verify(
            publicKey: response.publicKey, signature: response.signature,
            nonce: nonce, hostCertSHA256: Array(pin)))
    }

    @Test func makeReturnsNilForWrongLengthPin() throws {
        let identity = try ClientIdentity.loadOrCreate(store: MemoryStore())
        let nonce = [UInt8](repeating: 0x11, count: 32)
        let shortPin = Data(repeating: 0x22, count: 16)
        let auth = ChallengeResponse.make(
            identity: identity, challenge: ServerChallenge(nonce: nonce), pinnedCertSHA256: shortPin)
        #expect(auth == nil)
    }

    @Test func responseBindsTheIssuedChallengeNotADifferentOne() throws {
        let identity = try ClientIdentity.loadOrCreate(store: MemoryStore())
        let nonce = [UInt8](repeating: 0x11, count: 32)
        let pin = Data(repeating: 0x22, count: 32)
        let auth = ChallengeResponse.make(
            identity: identity, challenge: ServerChallenge(nonce: nonce), pinnedCertSHA256: pin)
        let response = try #require(auth)
        var otherNonce = nonce
        otherNonce[0] ^= 0xFF
        #expect(!ClientAuthCrypto.verify(
            publicKey: response.publicKey, signature: response.signature,
            nonce: otherNonce, hostCertSHA256: Array(pin)))
    }
}

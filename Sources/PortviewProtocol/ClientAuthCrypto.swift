// SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit

/// Pure crypto for the mutual-auth signed challenge (spec §3). The client signs, the host verifies;
/// both derive the exact same signed payload so no ambiguity or negotiation is possible.
///
/// Signed payload = `UTF8("Portview client-auth v1") ‖ nonce[32] ‖ hostCertSHA256[32]` — a frozen,
/// fixed-width concatenation (both trailing fields are 32 bytes, so it is unambiguous without length
/// prefixes; the version tag domain-separates it and lets the construction be rolled).
///
/// - Binding `nonce` (fresh, single-use, connection-local) defeats replay: a prior signature never
///   verifies against a new challenge.
/// - Binding `hostCertSHA256` — the pin the client ALREADY holds from its pinned dial, never a
///   server-supplied value — defeats relay/MITM: a host presenting a different cert gets a
///   signature over a different hash, which the real host rejects.
public enum ClientAuthCrypto {
    /// Domain-separation tag / version for the signed payload. Bump to roll the construction.
    static let payloadTag = "Portview client-auth v1"

    /// The exact bytes the client signs and the host verifies. Deterministic (the signature itself
    /// is not — CryptoKit hedges Ed25519 — so tests freeze THIS, and round-trip the signature).
    public static func signedPayload(nonce: [UInt8], hostCertSHA256: [UInt8]) -> [UInt8] {
        Array(payloadTag.utf8) + nonce + hostCertSHA256
    }

    /// Both payload fields are fixed-width 32 bytes; the framing is unambiguous ONLY at these
    /// widths, so sign/verify enforce them (a signer fed an empty cert hash would otherwise
    /// silently omit the relay binding).
    static let fieldWidth = 32

    /// Client side: sign the challenge with the device private key. Throws on inputs that are not
    /// exactly 32 bytes each — the frozen contract has no variable-length form.
    public static func sign(privateKey: Curve25519.Signing.PrivateKey,
                            nonce: [UInt8], hostCertSHA256: [UInt8]) throws -> [UInt8] {
        guard nonce.count == fieldWidth, hostCertSHA256.count == fieldWidth else {
            throw ClientAuthCryptoError.invalidFieldWidth
        }
        let payload = signedPayload(nonce: nonce, hostCertSHA256: hostCertSHA256)
        return Array(try privateKey.signature(for: Data(payload)))
    }

    /// Host side: verify `signature` is valid for `publicKey` over the payload the host issued.
    /// Returns false on any malformed input rather than throwing (an authorization check must fail
    /// closed, never crash the accept path). The caller has already confirmed `publicKey` matches
    /// an enrolled record; this confirms possession of the matching private key for THIS nonce.
    public static func verify(publicKey: [UInt8], signature: [UInt8],
                              nonce: [UInt8], hostCertSHA256: [UInt8]) -> Bool {
        guard nonce.count == fieldWidth, hostCertSHA256.count == fieldWidth else { return false }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: Data(publicKey)) else {
            return false
        }
        let payload = signedPayload(nonce: nonce, hostCertSHA256: hostCertSHA256)
        return key.isValidSignature(Data(signature), for: Data(payload))
    }
}

public enum ClientAuthCryptoError: Error {
    case invalidFieldWidth
}

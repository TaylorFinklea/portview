import Foundation
import CryptoKit

/// Pure derivation for the 6-digit SAS pairing code (commit-then-reveal). No I/O, no logging, no
/// randomness in the derive/commit functions (so the known-answer test can pin the wire contract).
/// See docs/superpowers/specs/2026-06-19-sas-pairing-v2-commit-reveal.md.
///
/// The code binds the host's leaf-cert SHA-256, so an active MITM presenting a different cert gets a
/// different code; the two-sided commit (nonce committed before either side reveals) stops the MITM
/// from grinding a substituted nonce to force the codes equal.
public enum SASCode {
    /// Domain-separation tag for the nonce commitment (DISTINCT from `deriveInfo`).
    static let commitTag = "Portview SAS commit v2"
    /// HKDF `info` / version tag for the final code derivation (bump to roll the construction).
    static let deriveInfo = "Portview SAS v2"
    /// HKDF `info` for the Guardrail-E confirmation key — DISTINCT from `deriveInfo`/`commitTag` so the
    /// confirm key is domain-separated from the code derivation (no cross-protocol key reuse).
    static let confirmInfo = "Portview SAS confirm v2"
    /// Nonce length in bytes (128-bit; hides under a 2^128 commitment preimage).
    public static let nonceLength = 16

    /// Which side a commitment is for — bound into the commit so a client commit can't be replayed
    /// as a host commit (reflection defense).
    public enum Role: UInt8, Sendable {
        case client = 0x00
        case host = 0x01
    }

    /// Commitment over a nonce: `SHA256(commitTag ‖ role ‖ certSHA256 ‖ nonce)`. Hiding (2^128
    /// preimage of the 16-byte nonce) and binding (2^256 second preimage); the cert binding forces a
    /// MITM to mint its own commit per leg (a forwarded commit fails the other leg's `verify`).
    public static func commit(nonce: [UInt8], role: Role, certSHA256: [UInt8]) -> [UInt8] {
        var input = Data(commitTag.utf8)
        input.append(role.rawValue)
        input.append(contentsOf: certSHA256)
        input.append(contentsOf: nonce)
        return Array(SHA256.hash(data: input))
    }

    /// True iff `nonce` opens `commitment` for the given role + cert.
    public static func verify(commitment: [UInt8], nonce: [UInt8], role: Role, certSHA256: [UInt8]) -> Bool {
        commit(nonce: nonce, role: role, certSHA256: certSHA256) == commitment
    }

    /// The 6-digit code: `HKDF<SHA256>(ikm: clientNonce‖hostNonce, salt: certSHA256,
    /// info: "Portview SAS v2", L: 8)` read as a big-endian UInt64, `% 1_000_000`, zero-padded to 6.
    /// L=8 keeps the modular bias < 2^-44 (a 20-bit value `% 1e6` was ~2× biased at the low end).
    public static func derive(clientNonce: [UInt8], hostNonce: [UInt8], certSHA256: [UInt8]) -> String {
        let ikm = clientNonce + hostNonce
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: Data(certSHA256),
            info: Data(deriveInfo.utf8),
            outputByteCount: 8)
        let bytes = key.withUnsafeBytes { Array($0) }
        var value: UInt64 = 0
        for b in bytes { value = (value << 8) | UInt64(b) }  // big-endian
        return String(format: "%06d", Int(value % 1_000_000))
    }

    /// Optional (Guardrail E) authenticated confirmation the client sends the host AFTER the user-typed
    /// code matched, so the host gets a positive "✓ a client confirmed" signal. The key is HKDF-derived
    /// with a DISTINCT info from `derive` (structural domain separation — no cross-protocol key reuse),
    /// then HMACs a fixed message. Both sides compute it from values they already hold; the host must
    /// verify it constant-time (`verifyConfirmation`), never with `==`.
    public static func confirmation(clientNonce: [UInt8], hostNonce: [UInt8], certSHA256: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: Data("confirm".utf8), using: confirmKey(clientNonce, hostNonce, certSHA256)))
    }

    /// Constant-time check that `mac` is a valid confirmation for these nonces + cert.
    public static func verifyConfirmation(_ mac: [UInt8], clientNonce: [UInt8], hostNonce: [UInt8], certSHA256: [UInt8]) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(Data(mac), authenticating: Data("confirm".utf8),
                                               using: confirmKey(clientNonce, hostNonce, certSHA256))
    }

    private static func confirmKey(_ clientNonce: [UInt8], _ hostNonce: [UInt8], _ certSHA256: [UInt8]) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: clientNonce + hostNonce),
            salt: Data(certSHA256),
            info: Data(confirmInfo.utf8),
            outputByteCount: 32)
    }

    /// A fresh CSPRNG nonce (`SystemRandomNumberGenerator` is CSPRNG-backed on Apple platforms).
    /// Drawn fresh per pairing attempt; never persisted or reused.
    public static func randomNonce() -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        return (0..<nonceLength).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
    }
}

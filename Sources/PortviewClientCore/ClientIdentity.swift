// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation
import PortviewProtocol
import PortviewTransport

// Client-side persistent device identity (mutual-auth spec §1,
// docs/superpowers/specs/2026-07-01-revocable-pairing-mutual-auth.md). One Curve25519 signing
// keypair per device (keychain-persisted — iOS keychain items can outlive an app reinstall, so
// this is NOT per-install; `rotate` is the sanctioned way to abandon a key). The host enrolls
// the PUBLIC key (PairingStore) and every streaming
// handshake proves possession of the private key via the signed challenge (ClientAuthCrypto).
// The private key never leaves this type except as the persisted blob in the injected store.

/// Storage seam for the persisted private key (real impl: iOS Keychain in the client app; tests
/// inject memory). Mirrors the host's `IdentityRecordStore`/`PairingRecordStore` pattern — one
/// dedicated item persisting one opaque blob (the private key's `rawRepresentation`).
public protocol ClientIdentityStore: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

/// The device's signing identity. `deviceID` = SHA-256 of the raw public key, hex — computed via
/// `PairingStore.deviceID` so the client id and the host's enrollment-map key match by
/// construction, never by parallel derivations that can drift.
public struct ClientIdentity: Sendable {
    /// Serializes the read-mint-write critical section so two concurrent first-launch callers
    /// can't each mint a key with the second write silently overwriting the first — the returned
    /// identity must BE the persisted identity, or the host could enroll a key that vanishes on
    /// the next launch. Mirrors `TLSIdentity.persistenceLock`.
    private static let creationLock = NSLock()

    private let privateKey: Curve25519.Signing.PrivateKey

    /// Raw public-key representation (32 bytes) — the only key material that ever goes on the wire.
    public var publicKey: Data { privateKey.publicKey.rawRepresentation }

    /// The id the host enrolls and authorizes by.
    public var deviceID: String { PairingStore.deviceID(forPublicKey: publicKey) }

    /// Load the persisted identity, or mint-and-persist a fresh one.
    ///
    /// Failure policy (deliberate, direction-dependent):
    /// - A THROWING read (e.g. keychain locked) is potentially transient → propagate; minting a
    ///   fresh key here would permanently destroy an identity the host may already have enrolled.
    /// - A successful read of an UNDECODABLE blob is permanent damage with no other recovery path
    ///   → mint fresh (fresh-install semantics; the host fails closed on the unknown key until the
    ///   device is re-enrolled).
    /// - A THROWING write on create → propagate; an unpersisted identity could be enrolled during
    ///   pairing and then vanish on the next launch.
    public static func loadOrCreate(store: ClientIdentityStore) throws -> ClientIdentity {
        creationLock.lock()
        defer { creationLock.unlock() }
        if let blob = try store.read(),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: blob) {
            return ClientIdentity(privateKey: key)
        }
        let key = Curve25519.Signing.PrivateKey()
        try store.write(key.rawRepresentation)
        return ClientIdentity(privateKey: key)
    }

    /// Explicitly abandon the current identity and mint-and-persist a fresh one — the ONLY
    /// sanctioned rotation path (Sol review, 2026-07-22: a compromised key must be replaceable
    /// without relying on app-reinstall, since iOS keychain items can survive uninstall). Never
    /// called automatically; the attended ceremony around it is han.3/han.4 UI. The new key is
    /// persisted BEFORE it is exposed; a failed write propagates and leaves the old identity
    /// intact. The old key becomes useless to its holder once the host revokes/re-enrolls.
    public static func rotate(store: ClientIdentityStore) throws -> ClientIdentity {
        creationLock.lock()
        defer { creationLock.unlock() }
        let key = Curve25519.Signing.PrivateKey()
        try store.write(key.rawRepresentation)
        return ClientIdentity(privateKey: key)
    }

    /// Sign the host's challenge (spec §3): the frozen payload binds the fresh nonce (replay
    /// defense) and the client-held cert pin (relay defense).
    public func sign(nonce: [UInt8], hostCertSHA256: [UInt8]) throws -> [UInt8] {
        try ClientAuthCrypto.sign(privateKey: privateKey, nonce: nonce, hostCertSHA256: hostCertSHA256)
    }
}

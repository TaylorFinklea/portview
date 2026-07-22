// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation
import PortviewProtocol
import Testing

@testable import PortviewClientCore

struct ClientIdentityTests {
    private enum TestStoreError: Error { case injected }

    /// In-memory `ClientIdentityStore` for tests; can be told to throw to simulate a locked
    /// keychain (read) or a full/denied keychain (write). Mirrors PairingStoreTests.MemoryStore.
    private final class MemoryStore: ClientIdentityStore, @unchecked Sendable {
        private let lock = NSLock()
        private var blob: Data?
        private var _failRead = false
        private var _failWrite = false
        private var _writeCount = 0

        init(_ blob: Data? = nil) { self.blob = blob }

        var failRead: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _failRead }
            set { lock.lock(); defer { lock.unlock() }; _failRead = newValue }
        }
        var failWrite: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _failWrite }
            set { lock.lock(); defer { lock.unlock() }; _failWrite = newValue }
        }
        var writeCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _writeCount
        }

        func read() throws -> Data? {
            lock.lock(); defer { lock.unlock() }
            if _failRead { throw TestStoreError.injected }
            return blob
        }

        func write(_ data: Data) throws {
            lock.lock(); defer { lock.unlock() }
            if _failWrite { throw TestStoreError.injected }
            _writeCount += 1
            blob = data
        }

        var storedBlob: Data? {
            lock.lock(); defer { lock.unlock() }
            return blob
        }
    }

    /// Fixed 32-byte private-key raw representation for frozen-vector tests.
    private static let fixedPrivateRaw = Data((UInt8(1)...32).map { $0 })
    /// Frozen expected outputs for `fixedPrivateRaw` (generated once from CryptoKit; freezing them
    /// pins the persisted-blob format and the deviceID derivation as cross-module contracts).
    private static let fixedPublicHex =
        "79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664"
    private static let fixedDeviceID =
        "65b60673d6ed884bf01c2c222d82ada0740f29ac3355d6a925c81f17f47a27b8"

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    @Test func createsAndPersistsFreshIdentityWhenAbsent() throws {
        let store = MemoryStore()
        let identity = try ClientIdentity.loadOrCreate(store: store)
        #expect(store.writeCount == 1)
        #expect(store.storedBlob?.count == 32)  // blob = private key rawRepresentation
        #expect(identity.publicKey.count == 32)
        // Reloading from the same store yields the SAME identity (stable across launches).
        let reloaded = try ClientIdentity.loadOrCreate(store: store)
        #expect(reloaded.publicKey == identity.publicKey)
        #expect(store.writeCount == 1)  // load path never rewrites
    }

    @Test func loadsStoredIdentityWithFrozenPublicKey() throws {
        let store = MemoryStore(Self.fixedPrivateRaw)
        let identity = try ClientIdentity.loadOrCreate(store: store)
        #expect(hex(identity.publicKey) == Self.fixedPublicHex)
        #expect(store.writeCount == 0)
    }

    @Test func deviceIDIsFrozenSHA256HexOfPublicKey() throws {
        let store = MemoryStore(Self.fixedPrivateRaw)
        let identity = try ClientIdentity.loadOrCreate(store: store)
        // The contract the host's PairingStore enrollment map keys on: SHA256(pubkey) hex.
        #expect(identity.deviceID == Self.fixedDeviceID)
    }

    @Test func signedChallengeVerifiesUnderClientAuthCrypto() throws {
        let store = MemoryStore()
        let identity = try ClientIdentity.loadOrCreate(store: store)
        let nonce = [UInt8](repeating: 0xA5, count: 32)
        let certHash = [UInt8](repeating: 0x3C, count: 32)
        let signature = try identity.sign(nonce: nonce, hostCertSHA256: certHash)
        #expect(ClientAuthCrypto.verify(
            publicKey: Array(identity.publicKey), signature: signature,
            nonce: nonce, hostCertSHA256: certHash))
        // A different nonce must not verify (the replay defense, visible at this layer).
        var otherNonce = nonce
        otherNonce[0] ^= 0xFF
        #expect(!ClientAuthCrypto.verify(
            publicKey: Array(identity.publicKey), signature: signature,
            nonce: otherNonce, hostCertSHA256: certHash))
    }

    @Test func readErrorPropagatesAndNeverRegenerates() throws {
        // A throwing read (e.g. keychain locked) is potentially TRANSIENT: minting a fresh key here
        // would overwrite — and permanently destroy — an identity the host may already have
        // enrolled. The error must propagate and the store must not be written.
        let store = MemoryStore(Self.fixedPrivateRaw)
        store.failRead = true
        #expect(throws: TestStoreError.self) {
            _ = try ClientIdentity.loadOrCreate(store: store)
        }
        #expect(store.writeCount == 0)
    }

    @Test func corruptBlobRegeneratesFreshIdentity() throws {
        // A SUCCESSFUL read of undecodable bytes is PERMANENT damage — no retry will fix it, and
        // the client has no other recovery path (fresh-install semantics: mint a new identity; the
        // host fails closed on the unknown key until the device is re-enrolled).
        let store = MemoryStore(Data([0xDE, 0xAD]))  // not a valid 32-byte raw representation
        let identity = try ClientIdentity.loadOrCreate(store: store)
        #expect(identity.publicKey.count == 32)
        #expect(store.writeCount == 1)
        #expect(store.storedBlob?.count == 32)  // healed: the new key is persisted
    }

    @Test func concurrentLoadOrCreateAgreesOnOnePersistedIdentity() async throws {
        // Two concurrent first-launch callers must not each mint a key with the second write
        // silently overwriting the first (returned identity ≠ persisted identity → the host could
        // enroll a key that vanishes on the next launch). Kimi K3 review finding F1; mirrors the
        // `TLSIdentity.persistenceLock` precedent.
        let store = MemoryStore()
        let keys = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<32 {
                group.addTask { try ClientIdentity.loadOrCreate(store: store).publicKey }
            }
            return try await group.reduce(into: [Data]()) { $0.append($1) }
        }
        #expect(Set(keys).count == 1)  // every caller got the same identity
        #expect(store.writeCount == 1)  // exactly one mint
        // And the agreed identity IS the persisted one.
        let persisted = try ClientIdentity.loadOrCreate(store: store)
        #expect(persisted.publicKey == keys[0])
    }

    @Test func rotateMintsPersistsAndReplacesTheIdentity() throws {
        // Explicit rotation is the ONLY sanctioned way to abandon a key (Sol review: a compromised
        // key must be replaceable without relying on app-reinstall, since iOS keychain items can
        // survive uninstall). Rotation persists the new key BEFORE exposing it, and the old key is
        // gone from the store afterward.
        let store = MemoryStore(Self.fixedPrivateRaw)
        let old = try ClientIdentity.loadOrCreate(store: store)
        let rotated = try ClientIdentity.rotate(store: store)
        #expect(rotated.publicKey != old.publicKey)
        #expect(store.storedBlob != Self.fixedPrivateRaw)
        // Subsequent loads return the rotated identity.
        let reloaded = try ClientIdentity.loadOrCreate(store: store)
        #expect(reloaded.publicKey == rotated.publicKey)
    }

    @Test func rotateWriteErrorPropagatesAndKeepsOldIdentity() throws {
        // A failed rotation must not strand the device keyless or hand out an unpersisted key.
        let store = MemoryStore(Self.fixedPrivateRaw)
        store.failWrite = true
        #expect(throws: TestStoreError.self) {
            _ = try ClientIdentity.rotate(store: store)
        }
        #expect(store.storedBlob == Self.fixedPrivateRaw)  // old identity intact
    }

    @Test func writeErrorOnFreshCreatePropagates() throws {
        // Never hand out an identity that was not persisted: the host could enroll it during
        // pairing and the key would vanish on the next launch (silent un-enrollment).
        let store = MemoryStore()
        store.failWrite = true
        #expect(throws: TestStoreError.self) {
            _ = try ClientIdentity.loadOrCreate(store: store)
        }
    }
}

// SPDX-License-Identifier: Apache-2.0
import Foundation
import Security
import CryptoKit

// Host-side revocable client enrollment (mutual-auth spec §2,
// docs/superpowers/specs/2026-07-01-revocable-pairing-mutual-auth.md). A client is a persistent
// Curve25519 signing keypair; the host enrolls its public key here during attended pairing and
// checks `isAuthorized` on every streaming handshake BEFORE building any session scaffolding.
// Revoking makes the device's next handshake fail closed.

/// One enrolled client device. `id` = SHA-256 of `publicKey` (raw representation), hex.
public struct EnrolledClient: Codable, Equatable, Sendable {
    public let id: String
    public let publicKey: Data
    public var deviceName: String
    public let enrolledAt: Date
    public var lastSeen: Date

    public init(id: String, publicKey: Data, deviceName: String, enrolledAt: Date, lastSeen: Date) {
        self.id = id
        self.publicKey = publicKey
        self.deviceName = deviceName
        self.enrolledAt = enrolledAt
        self.lastSeen = lastSeen
    }
}

/// Storage seam for the enrolled-client map (real impl: keychain; tests inject memory). Mirrors
/// `IdentityRecordStore`, but for a single dedicated item (its own keychain `service`) — the store
/// persists one opaque blob (the Codable `[id: EnrolledClient]` map).
protocol PairingRecordStore: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

/// Revocable enrollment gate. `actor` (matches the actor direction the transport is moving to) so
/// the decoded-map cache and the read-modify-write persistence are serialized without a lock.
///
/// FAIL-CLOSED is the load-bearing invariant (spec §2, dos-revocation review lens): this is an
/// authorization gate, the OPPOSITE of `TLSIdentity.loadOrCreatePersistent`'s deliberate
/// degrade-to-ephemeral. Any read/decode failure, or an absent/empty map, authorizes NOBODY.
/// To keep a keychain that locks mid-session from bricking a live host, the actor caches the map
/// after the first SUCCESSFUL read and authorizes from that cache; a read that throws never
/// populates the cache (so a denial is never cached as permission) and never clobbers persisted
/// data on a mutation.
public actor PairingStore {
    private let store: PairingRecordStore
    private let now: () -> Date
    /// Last known-good decoded map. `nil` = never read successfully yet.
    private var cache: [String: EnrolledClient]?

    init(store: PairingRecordStore, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    /// Real host store: a keychain generic-password item, device-only, distinct `service` from the
    /// TLS identity item (app-vs-CLI keychain-item convention).
    public init() {
        self.init(store: KeychainPairingStore())
    }

    /// The canonical device id for a raw public key: `SHA256(publicKey)` hex. The id-to-key binding
    /// is derived, never caller-asserted (a caller must not be able to enroll a key under a
    /// mismatched id, then get authorized by id alone — adversarial-review must-fix, 2026-07-21).
    public static func deviceID(forPublicKey publicKey: Data) -> String {
        SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
    }

    /// Instance mirror of `deviceID(forPublicKey:)` (convenience for the actor-isolated call sites).
    public func deviceID(forPublicKey publicKey: Data) -> String {
        Self.deviceID(forPublicKey: publicKey)
    }

    /// True iff `id` is currently enrolled. Fail-closed: a read/decode failure or absent map → false.
    public func isAuthorized(id: String) -> Bool {
        authorizedMap()[id] != nil
    }

    /// The enrolled record for a presented public key, or nil if not enrolled. Derives the id from
    /// the key and requires the STORED key to equal the presented key exactly — the auth gate must
    /// verify the challenge signature against this record's key, never trust an id in isolation.
    public func authorizedClient(forPublicKey publicKey: Data) -> EnrolledClient? {
        guard let record = authorizedMap()[Self.deviceID(forPublicKey: publicKey)],
              record.publicKey == publicKey else { return nil }
        return record
    }

    /// Every currently-enrolled client. Fail-closed to empty on a read/decode failure.
    public func list() -> [EnrolledClient] {
        Array(authorizedMap().values)
    }

    /// Enroll (or update) a client by its RAW public key — the id is derived internally
    /// (`SHA256(publicKey)`), never caller-supplied. Read-modify-write: reads the CURRENT map first
    /// so a concurrent entry isn't clobbered, and THROWS on a read failure rather than overwriting
    /// the persisted map with a lone new entry. Preserves `enrolledAt` on re-enroll; refreshes name
    /// + lastSeen.
    public func enroll(publicKey: Data, deviceName: String) throws {
        let id = Self.deviceID(forPublicKey: publicKey)
        var map = try mutableMap()
        let enrolledAt = map[id]?.enrolledAt ?? now()
        map[id] = EnrolledClient(id: id, publicKey: publicKey, deviceName: deviceName,
                                 enrolledAt: enrolledAt, lastSeen: now())
        try persist(map)
    }

    /// Revoke a client. The next handshake's `isAuthorized` returns false → connection closed
    /// pre-scaffolding. A no-op (and no write) if the id wasn't enrolled.
    public func revoke(id: String) throws {
        var map = try mutableMap()
        guard map.removeValue(forKey: id) != nil else { return }
        try persist(map)
    }

    /// Update a client's `lastSeen` (called on a successful authenticated handshake). No-op if
    /// the id isn't enrolled.
    public func touch(id: String) throws {
        var map = try mutableMap()
        guard var entry = map[id] else { return }
        entry.lastSeen = now()
        map[id] = entry
        try persist(map)
    }

    // MARK: - Internals

    /// Authorization view: cache if present, else a swallow-errors read (fail closed to empty,
    /// caching only a genuinely-successful read/absent state — never a thrown read).
    private func authorizedMap() -> [String: EnrolledClient] {
        if let cache { return cache }
        do {
            let map = try readMap()
            cache = map
            return map
        } catch {
            return [:]  // fail closed; do NOT cache — a later successful read may populate.
        }
    }

    /// Mutation view: cache if present, else a read that PROPAGATES failure (so a mutation never
    /// starts from a partial/empty map and silently drops persisted entries).
    private func mutableMap() throws -> [String: EnrolledClient] {
        if let cache { return cache }
        let map = try readMap()
        cache = map
        return map
    }

    private func readMap() throws -> [String: EnrolledClient] {
        guard let data = try store.read() else { return [:] }  // absent = nobody enrolled yet
        return try JSONDecoder().decode([String: EnrolledClient].self, from: data)
    }

    private func persist(_ map: [String: EnrolledClient]) throws {
        let data = try JSONEncoder().encode(map)
        try store.write(data)
        cache = map
    }
}

/// Keychain-backed store: one generic-password item holding the encoded enrolled-client map,
/// device-only (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), in its own `service` distinct
/// from the TLS-identity item. Mirrors `KeychainIdentityStore`.
struct KeychainPairingStore: PairingRecordStore {
    private let service = "dev.finklea.portview.pairings"
    private let account = "enrolled-clients"

    func read() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw PairingStoreError.keychainError(status)
        }
        return data
    }

    func write(_ data: Data) throws {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update = SecItemUpdate(key as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        if update == errSecItemNotFound {
            var add = key
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(add as CFDictionary, nil)
            if status == errSecDuplicateItem {
                let retry = SecItemUpdate(key as CFDictionary, [kSecValueData as String: data] as CFDictionary)
                guard retry == errSecSuccess else { throw PairingStoreError.keychainError(retry) }
                return
            }
            guard status == errSecSuccess else { throw PairingStoreError.keychainError(status) }
            return
        }
        throw PairingStoreError.keychainError(update)
    }
}

enum PairingStoreError: Error {
    case keychainError(OSStatus)
}

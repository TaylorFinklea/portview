// SPDX-License-Identifier: Apache-2.0
import Foundation
import Security
import CryptoKit

// Host-side revocable client enrollment (mutual-auth spec §2,
// docs/superpowers/specs/2026-07-01-revocable-pairing-mutual-auth.md). A client is a persistent
// Curve25519 signing keypair; the host enrolls its public key here during attended pairing and
// checks `isAuthorized` on every streaming handshake BEFORE building any session scaffolding.
// Revoking makes the device's next handshake fail closed.

/// The rollout-policy view of the enrollment store (mutual-auth §4-RESOLVED). DISTINCT from
/// `isAuthorized`/`list`, which fail closed to empty: a policy that reads a keychain error as
/// "empty" would REOPEN bootstrap on a transient failure (Sol han.1 review, CRITICAL). `.unreadable`
/// lets the policy fail closed to `.required` instead.
public enum EnrollmentSnapshot: Sendable, Equatable {
    /// The store was read successfully and holds no enrolled clients.
    case empty
    /// The store was read successfully and holds at least one enrolled client.
    case populated
    /// The store could not be read/decoded — treat as "not verifiably empty" (fail closed).
    case unreadable
}

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
    /// The persisted shape: the enrolled-client map PLUS a durable `migrationComplete` marker.
    /// The marker is set the first time ANY device enrolls and is NEVER cleared by revoke — so
    /// revoking the last device (or a fresh host start over that store) can't reopen the legacy
    /// bootstrap to a silent peer (Sol han.1 review, CRITICAL: promotion must be durable +
    /// monotonic, not derived from the CURRENT map emptiness).
    struct Persisted: Codable {
        var clients: [String: EnrolledClient]
        var migrationComplete: Bool
    }

    private let store: PairingRecordStore
    private let now: () -> Date
    /// Last known-good decoded state. `nil` = never read successfully yet.
    private var cache: Persisted?

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

    /// The rollout-policy view. `.populated` = migration is complete (a device is enrolled now OR
    /// the durable marker records one ever was) → the gate must require auth. `.empty` = verified
    /// never-enrolled → bootstrap may stay open. `.unreadable` = a cold read threw → fail closed to
    /// require (a keychain error must NOT be read as "empty → open"). The policy MUST use this, not
    /// `list().isEmpty`, for both the durability and the fail-closed reasons (Sol han.1, CRITICAL).
    public func enrollmentSnapshot() -> EnrollmentSnapshot {
        if let state = readState() {
            return (state.migrationComplete || !state.clients.isEmpty) ? .populated : .empty
        }
        return .unreadable  // NOT verifiably empty — never populates the cache
    }

    /// Enroll (or update) a client by its RAW public key — the id is derived internally
    /// (`SHA256(publicKey)`), never caller-supplied. Read-modify-write: reads the CURRENT map first
    /// so a concurrent entry isn't clobbered, and THROWS on a read failure rather than overwriting
    /// the persisted map with a lone new entry. Preserves `enrolledAt` on re-enroll; refreshes name
    /// + lastSeen.
    public func enroll(publicKey: Data, deviceName: String) throws {
        let id = Self.deviceID(forPublicKey: publicKey)
        var state = try mutableState()
        let enrolledAt = state.clients[id]?.enrolledAt ?? now()
        state.clients[id] = EnrolledClient(id: id, publicKey: publicKey, deviceName: deviceName,
                                           enrolledAt: enrolledAt, lastSeen: now())
        state.migrationComplete = true  // durable, monotonic: an enrollment ever happened.
        try persist(state)
    }

    /// Revoke a client. The next handshake's `isAuthorized` returns false → connection closed
    /// pre-scaffolding. A no-op (and no write) if the id wasn't enrolled. Never clears
    /// `migrationComplete` — revoking the last device leaves the gate at `.required`, not reopened.
    public func revoke(id: String) throws {
        var state = try mutableState()
        guard state.clients.removeValue(forKey: id) != nil else { return }
        try persist(state)
    }

    /// Update a client's `lastSeen` (called on a successful authenticated handshake). No-op if
    /// the id isn't enrolled.
    public func touch(id: String) throws {
        var state = try mutableState()
        guard var entry = state.clients[id] else { return }
        entry.lastSeen = now()
        state.clients[id] = entry
        try persist(state)
    }

    // MARK: - Internals

    /// Authorization view: the client map, fail-closed to empty on a read/decode failure.
    private func authorizedMap() -> [String: EnrolledClient] {
        readState()?.clients ?? [:]
    }

    /// Read view: cache if warm, else a swallow-errors read caching only a genuinely-successful
    /// state. Returns nil on a thrown read (fail closed; never caches a denial as permission).
    private func readState() -> Persisted? {
        if let cache { return cache }
        do {
            let state = try readPersisted()
            cache = state
            return state
        } catch {
            return nil
        }
    }

    /// Mutation view: cache if warm, else a read that PROPAGATES failure (so a mutation never
    /// starts from a partial/empty state and silently drops persisted entries or the marker).
    private func mutableState() throws -> Persisted {
        if let cache { return cache }
        let state = try readPersisted()
        cache = state
        return state
    }

    private func readPersisted() throws -> Persisted {
        guard let data = try store.read() else {
            return Persisted(clients: [:], migrationComplete: false)  // absent = nobody ever enrolled
        }
        if let state = try? JSONDecoder().decode(Persisted.self, from: data) { return state }
        // Back-compat: the han.2-era format was a bare `[id: EnrolledClient]` map. A non-empty
        // legacy map means migration already happened; an empty one means it hadn't.
        let map = try JSONDecoder().decode([String: EnrolledClient].self, from: data)
        return Persisted(clients: map, migrationComplete: !map.isEmpty)
    }

    private func persist(_ state: Persisted) throws {
        let data = try JSONEncoder().encode(state)
        try store.write(data)
        cache = state
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

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

/// Storage seam for a single opaque blob item (real impl: keychain; tests inject memory). Mirrors
/// `IdentityRecordStore`, but for a single dedicated item (its own keychain `service`). `PairingStore`
/// holds TWO independent instances of this seam — one for the authorization item (`Persisted.clients`
/// + `migrationComplete`), one for the separate lastSeen item (§6c, han.4 H-a) — so a lastSeen bump
/// can never share a blob (and therefore never share a write) with the authorization set.
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
///
/// `lastSeen` lives in a SEPARATE keychain item (§6c, han.4 H-a,
/// docs/superpowers/specs/2026-07-24-revoke-and-registry-design.md). The authorization item
/// (`clients` + `migrationComplete`) is mutated ONLY by `enroll`/`revoke`; `touch` reads-modifies-
/// writes only the lastSeen item, so a cosmetic lastSeen bump — even from a stale cross-process
/// cache — can never durably re-add a revoked key to the authorization set (finding 6, H-a).
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
    private let lastSeenStore: PairingRecordStore
    private let now: () -> Date
    /// Last known-good decoded state. `nil` = never read successfully yet.
    private var cache: Persisted?

    /// Two-arg convenience: existing call sites that predate the lastSeen split (§6c, H-a) keep
    /// compiling unchanged. `lastSeenStore` falls back to an ephemeral in-memory store — fine for
    /// callers that don't exercise `touch`/lastSeen persistence across instances.
    init(store: PairingRecordStore, now: @escaping () -> Date = Date.init) {
        self.init(store: store, lastSeenStore: EphemeralPairingRecordStore(), now: now)
    }

    /// Full init: separate stores for the authorization item and the lastSeen item (§6c, H-a) — see
    /// `KeychainPairingStore`/`KeychainLastSeenStore` below for the real keychain-backed pair.
    init(store: PairingRecordStore, lastSeenStore: PairingRecordStore, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.lastSeenStore = lastSeenStore
        self.now = now
    }

    /// Real host store: TWO keychain generic-password items, device-only, each with its own
    /// `service` distinct from the TLS identity item AND from each other (§6c, H-a — the split is
    /// what makes `touch` structurally unable to rewrite the authorization set).
    public init() {
        self.init(store: KeychainPairingStore(), lastSeenStore: KeychainLastSeenStore())
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

    /// Every currently-enrolled client, with `lastSeen` JOINED from the separate lastSeen item
    /// (§6c, H-a) — defaulting to `enrolledAt` when that item has no entry for the id. An orphan
    /// lastSeen entry for an id absent from the authorization set is never surfaced (iterates the
    /// authorization set, not the lastSeen map). Fail-closed to empty on an authorization
    /// read/decode failure (unchanged); a lastSeen read failure no-ops the join (falls back to
    /// `enrolledAt` for everyone) without affecting WHICH clients are returned.
    public func list() -> [EnrolledClient] {
        let seen = (try? readLastSeenState()) ?? [:]
        return authorizedMap().values.map { entry in
            var joined = entry
            joined.lastSeen = seen[entry.id] ?? entry.enrolledAt
            return joined
        }
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
    /// the persisted map with a lone new entry. Preserves `enrolledAt` on re-enroll; refreshes name.
    /// The stored `EnrolledClient.lastSeen` is a placeholder (`enrolledAt`) — it is NEVER read back
    /// out; `list()` joins the real value from the separate lastSeen item (§6c, H-a). Also seeds
    /// that item's `lastSeen[id]`, best-effort — a lastSeen failure must not fail the enrollment.
    public func enroll(publicKey: Data, deviceName: String) throws {
        let id = Self.deviceID(forPublicKey: publicKey)
        var state = try mutableState()
        let enrolledAt = state.clients[id]?.enrolledAt ?? now()
        state.clients[id] = EnrolledClient(id: id, publicKey: publicKey, deviceName: deviceName,
                                           enrolledAt: enrolledAt, lastSeen: enrolledAt)
        state.migrationComplete = true  // durable, monotonic: an enrollment ever happened.
        try persist(state)
        seedLastSeen(id: id)
    }

    /// Revoke a client. The next handshake's `isAuthorized` returns false → connection closed
    /// pre-scaffolding. A no-op (and no write) if the id wasn't enrolled. Never clears
    /// `migrationComplete` — revoking the last device leaves the gate at `.required`, not reopened.
    /// Also best-effort deletes `lastSeen[id]` from the separate lastSeen item (§6c, H-a) — a
    /// lastSeen failure must not fail the revoke, and doesn't retain the id in the authorization set.
    public func revoke(id: String) throws {
        var state = try mutableState()
        guard state.clients.removeValue(forKey: id) != nil else { return }
        try persist(state)
        deleteLastSeen(id: id)
    }

    /// Update a client's `lastSeen` (called on a successful authenticated handshake) in the
    /// SEPARATE lastSeen item ONLY (§6c, H-a) — never the authorization item. Best-effort: a
    /// thrown lastSeen read or write silently no-ops (mirrors the actor's existing mid-session
    /// keychain-lock resilience). Because this reads/writes ONLY the lastSeen item, it can never
    /// re-add a revoked key to the authorization set — the no-resurrect invariant holds BY
    /// CONSTRUCTION, not by a hoped-for read ordering (finding 6, H-a).
    public func touch(id: String) throws {
        guard var seen = try? readLastSeenState() else { return }
        seen[id] = now()
        try? writeLastSeen(seen)
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

    // MARK: - lastSeen (separate keychain item, §6c H-a)

    /// Reads the current lastSeen map, decoding an absent item as empty. Throws on a genuine store
    /// failure — callers decide how to degrade (`touch`/`enroll`/`revoke` swallow via `try?`;
    /// `list` falls back to `[:]`). Deliberately uncached: unlike the authorization item, a stale
    /// lastSeen read is not a security concern, so there is no resilience reason to keep serving a
    /// warm value once the keychain is reachable again.
    private func readLastSeenState() throws -> [String: Date] {
        guard let data = try lastSeenStore.read() else { return [:] }
        return try JSONDecoder().decode([String: Date].self, from: data)
    }

    private func writeLastSeen(_ seen: [String: Date]) throws {
        try lastSeenStore.write(try JSONEncoder().encode(seen))
    }

    /// Best-effort seed on enroll. Never throws upward — a lastSeen failure must not fail the
    /// enrollment (the enrollment's own auth-item write already succeeded by the time this runs).
    private func seedLastSeen(id: String) {
        guard var seen = try? readLastSeenState() else { return }
        seen[id] = now()
        try? writeLastSeen(seen)
    }

    /// Best-effort cleanup on revoke. Never throws upward — a lastSeen failure must not fail the
    /// revoke (the revoke's own auth-item write already succeeded by the time this runs).
    private func deleteLastSeen(id: String) {
        guard var seen = try? readLastSeenState() else { return }
        guard seen.removeValue(forKey: id) != nil else { return }
        try? writeLastSeen(seen)
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

/// Keychain-backed store for the SEPARATE lastSeen item (§6c, han.4 H-a): a distinct `service`
/// from the authorization item (`KeychainPairingStore`, above) so `touch` — which mutates only
/// this item — can never rewrite the authorization set, even from a stale cross-process cache.
/// Same device-only accessibility; mirrors `KeychainPairingStore`.
struct KeychainLastSeenStore: PairingRecordStore {
    private let service = "dev.finklea.portview.pairings.lastseen"
    private let account = "last-seen"

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

/// Ephemeral in-memory fallback for `lastSeenStore` — used by the two-arg `init(store:now:)` so
/// call sites that predate the lastSeen split (§6c, H-a) and don't inject a lastSeen store keep
/// compiling unchanged. Never persisted, never shared across instances.
private final class EphemeralPairingRecordStore: PairingRecordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var blob: Data?
    func read() throws -> Data? { lock.lock(); defer { lock.unlock() }; return blob }
    func write(_ data: Data) throws { lock.lock(); defer { lock.unlock() }; blob = data }
}

enum PairingStoreError: Error {
    case keychainError(OSStatus)
}

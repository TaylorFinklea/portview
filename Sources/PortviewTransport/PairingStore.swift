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

/// Why a `revoke` did not complete — and, the part that matters, what is actually KNOWN about the
/// durability of the fail-closed denial it leaves behind (Sol re-review I5 follow-up; three-way split
/// per Sol pass 3 N1). These are three materially different states and the UI must never render them
/// as one "revoke incomplete":
///
/// - `.fencedDurably` — the removal failed but the revocation intent is durably recorded (the item
///   was read and either already held the id or the fresh write landed). The device is denied now and
///   stays denied after a host restart; Retry finishes the removal.
/// - `.notDurable` — PROVEN absent: the intent item was read successfully, the id was NOT in it, and
///   the fresh write failed. This is the natural CORRELATED failure (both items live in the same
///   keychain, so whatever broke one usually broke the other), and it is honestly unfixable by
///   writing harder: if nothing durable can be written, nothing durable can deny after a restart. The
///   device is fenced ONLY by this process's in-memory `HostControl` lease and REGAINS ACCESS when
///   the host restarts. The store's job is to say so, loudly.
/// - `.durabilityUnknown` — the intent item could not be READ, so whether a durable fence exists is
///   UNKNOWN, not absent. Folding this into `.notDurable` was a factual error (Sol pass 3 N1): an
///   earlier attempt may have durably recorded the id, in which case a fresh process still denies it
///   — reporting a categorical "regains access on restart" is then simply false. It errs in the safe
///   direction, but honest reporting is the whole contract here, so it gets its own case and the UI
///   must render it CONDITIONALLY ("may regain access — could not verify").
public enum RevokeIncomplete: Error, Sendable, Equatable {
    case fencedDurably(reason: String)
    case notDurable(reason: String)
    case durabilityUnknown(reason: String)

    /// True iff the denial is PROVEN to survive a process restart (an intent is durably recorded).
    /// `.durabilityUnknown` is deliberately false — unproven is not proven.
    public var isDurablyFenced: Bool {
        switch self {
        case .fencedDurably: true
        case .notDurable, .durabilityUnknown: false
        }
    }

    /// True iff the ABSENCE of a durable fence is proven (read succeeded, id absent, write failed) —
    /// the only state in which "this device regains access if Portview restarts" may be stated
    /// categorically. Distinct from `!isDurablyFenced`, which is also true when nothing is known.
    public var isProvenNotDurable: Bool {
        switch self {
        case .notDurable: true
        case .fencedDurably, .durabilityUnknown: false
        }
    }
}

/// The UI view of the ids `authorizedMap()` currently denies for a reason the surface must render.
/// `.unreadable` is DELIBERATELY distinct from an empty `.known`: when the intent item cannot be read,
/// `authorizedMap()` denies EVERY device (fail closed, §6d), so rendering a clean empty list would
/// tell the user "nothing pending, all good" at the exact moment nothing at all is authorized. Fail
/// loud instead.
///
/// **`.known` is TAGGED BY PROVENANCE, never one flat set (Sol pass 4 F1).** Two structurally
/// different denials reach this accessor and they are NOT interchangeable:
///
/// - `durable` — a revoke was ASKED FOR (an authenticated `revoke`) and its intent is durably
///   recorded, so the device is denied across a restart. Retrying the durable removal is continuing
///   a decision the owner already authenticated.
/// - `enrollmentFenced` — nobody ever asked to revoke this device. Its own `enroll` could not verify
///   that no intent is pending, so THIS PROCESS fences it (`unverifiedIntentFence`, §6d item 8a). The
///   only authenticated decision in its history is an ADMIT.
///
/// Unioning the two into one untagged set let the app default an enrollment fence to the ordinary
/// "revoke incomplete" row — whose Retry ran a durable, destructive `revoke` with no confirmation and
/// no `LAContext`, i.e. a destructive action reachable with zero local presence. The provenance is
/// therefore part of the type, and the two sets are disjoint by construction (`durable` wins: a
/// recorded intent IS an authenticated revoke).
public enum PendingRevocations: Sendable, Equatable {
    case known(durable: Set<String>, enrollmentFenced: Set<String>)
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
/// holds THREE independent instances of this seam — one for the authorization item
/// (`Persisted.clients` + `migrationComplete`), one for the separate lastSeen item (§6c, han.4 H-a),
/// one for the pending-revocation-intent set (§6d, I5) — so neither a lastSeen bump nor an intent
/// write can ever share a blob (and therefore never share a write) with the authorization set.
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
///
/// **The cache contract is deliberately ASYMMETRIC (Sol re-review C2).** To keep a keychain that locks
/// mid-session from bricking a live host, the actor caches each item after its first SUCCESSFUL read
/// and serves the AUTHORIZATION READ path (`isAuthorized`/`authorizedClient`/`list`/
/// `enrollmentSnapshot`) from that cache; a read that throws never populates a cache (so a denial is
/// never cached as permission). The MUTATION path (`enroll`/`revoke` and every revocation-intent
/// write) NEVER reads a cache: it re-reads the durable item immediately before each read-modify-write
/// and propagates a read failure, because a warm-cache RMW is a lost update against an arbitrarily old
/// snapshot — P1 revokes K and writes {J}; P2, still warm on {K, J}, revokes J and writes {K},
/// durably resurrecting K while both calls report success. Re-reading narrows the window to the actual
/// RMW; it does not make it atomic (no cross-process CAS on a whole-blob keychain item — bead
/// `portview-auf`, design §9).
///
/// `lastSeen` lives in a SEPARATE keychain item (§6c, han.4 H-a,
/// docs/superpowers/specs/2026-07-24-revoke-and-registry-design.md). The authorization item
/// (`clients` + `migrationComplete`) is mutated ONLY by `enroll`/`revoke`; `touch` reads-modifies-
/// writes only the lastSeen item, so a cosmetic lastSeen bump — even from a stale cross-process
/// cache — can never durably re-add a revoked key to the authorization set (finding 6, H-a).
///
/// Pending REVOCATION INTENTS live in a THIRD keychain item (§6d, Sol re-review I5), mirroring that
/// split. `revoke` records the intent BEFORE attempting the durable removal and clears it only once
/// the removal has landed; while an intent is recorded the id is unauthorizable even though its
/// authorization record still exists. That is what makes §1a step 5's "a failed durable revoke leaves
/// K unauthorizable" true across a PROCESS RESTART — `HostControl`'s retained fence and the app's
/// `revokeFailures` are both in-memory only.
///
/// **That claim is CONDITIONAL on the intent write landing, and `revoke` says which of THREE things
/// it got.** The intent item shares a keychain with the authorization item, so the two writes fail
/// together in the natural case; when neither lands there is nothing durable to deny with, and a
/// restart re-admits the key. No storage trick fixes that (there is nowhere left to write) — so the
/// contract is to report it: `.fencedDurably` when the intent is durably recorded, `.notDurable` when
/// its absence is PROVEN (item read, id absent, write failed), and `.durabilityUnknown` when the item
/// could not be read at all. The third case is not a nicety: an earlier attempt may already have
/// recorded the intent durably, so claiming "regains access on restart" from a failed READ is false
/// (Sol pass 3 N1). The UI must render all three differently.
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
    private let intentStore: PairingRecordStore
    private let now: () -> Date
    /// Last known-good decoded state. `nil` = never read successfully yet.
    private var cache: Persisted?
    /// Last known-good decoded revocation-intent set. `nil` = never read successfully yet (the
    /// authorization path then fails closed — see `revocationIntents()`).
    private var intentCache: Set<String>?
    /// Ids denied for the REST OF THIS PROCESS because an operation on them ended with their durable
    /// intent state UNVERIFIED (Sol pass 3, N2). The hole it closes: `enroll` persists the
    /// authorization record (warming `cache` with the new key) and only then discharges the intent; if
    /// that discharge's READ throws, `enroll` throws `enrollmentStillFenced` — but a warm `intentCache`
    /// from before the failure (classically `[]`) still answers "nothing pending", so the very next
    /// signed handshake read the fresh authorization cache minus an empty intent set and ADMITTED the
    /// key the operation had just reported as failed. Enrollment said `approved: false`, the key
    /// worked.
    ///
    /// Deliberately a targeted per-id fence rather than poisoning `intentCache` wholesale: (a) dropping
    /// the warm cache would deny EVERY other live device on a transient mid-session keychain lock —
    /// exactly the brick-a-live-host regression the warm cache exists to prevent (§6d item 7) — and
    /// (b) it would not even be sufficient, because a later successful read that omits the id would
    /// re-admit it, while the operation that reported failure is still the last word. Fails CLOSED in
    /// every branch: it only ever subtracts, and it is lifted ONLY by `dischargeRevocationIntent`
    /// succeeding, i.e. by a genuine read of the durable item proving the id carries no intent.
    private var unverifiedIntentFence: Set<String> = []

    /// Two-arg convenience: existing call sites that predate the lastSeen split (§6c, H-a) and the
    /// revocation-intent item (§6d, I5) keep compiling unchanged. Both extra stores fall back to
    /// ephemeral in-memory items — fine for callers that don't exercise `touch` persistence or
    /// cross-instance (restart) revocation-intent behavior.
    init(store: PairingRecordStore, now: @escaping () -> Date = Date.init) {
        self.init(store: store, lastSeenStore: EphemeralPairingRecordStore(),
                  revokeIntentStore: EphemeralPairingRecordStore(), now: now)
    }

    /// lastSeen-injecting convenience (§6c, H-a) with an ephemeral intent item.
    init(store: PairingRecordStore, lastSeenStore: PairingRecordStore, now: @escaping () -> Date = Date.init) {
        self.init(store: store, lastSeenStore: lastSeenStore,
                  revokeIntentStore: EphemeralPairingRecordStore(), now: now)
    }

    /// Intent-injecting convenience (§6d, I5) with an ephemeral lastSeen item — the shape the
    /// restart tests need (a shared intent item across two instances).
    init(store: PairingRecordStore, revokeIntentStore: PairingRecordStore, now: @escaping () -> Date = Date.init) {
        self.init(store: store, lastSeenStore: EphemeralPairingRecordStore(),
                  revokeIntentStore: revokeIntentStore, now: now)
    }

    /// Full init: separate stores for the authorization item, the lastSeen item (§6c, H-a) and the
    /// pending-revocation-intent item (§6d, I5) — see `KeychainPairingStore` /
    /// `KeychainLastSeenStore` / `KeychainRevokeIntentStore` below for the real keychain-backed trio.
    init(store: PairingRecordStore, lastSeenStore: PairingRecordStore,
         revokeIntentStore: PairingRecordStore, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.lastSeenStore = lastSeenStore
        self.intentStore = revokeIntentStore
        self.now = now
    }

    /// Real host store: THREE keychain generic-password items, device-only, each with its own
    /// `service` distinct from the TLS identity item AND from each other — the authorization set, the
    /// lastSeen map (§6c, H-a — the split is what makes `touch` structurally unable to rewrite the
    /// authorization set), and the pending-revocation-intent set (§6d, I5 — what makes revoke's
    /// fail-closed claim survive a process restart).
    public init() {
        self.init(store: KeychainPairingStore(), lastSeenStore: KeychainLastSeenStore(),
                  revokeIntentStore: KeychainRevokeIntentStore())
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

    /// True iff `id` is currently enrolled AND has no pending revocation intent (§6d). Fail-closed: a
    /// read/decode failure on EITHER item, or an absent map, → false.
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

    /// The INVENTORY view: every client present in the authorization item, with `lastSeen` JOINED from
    /// the separate lastSeen item (§6c, H-a) — defaulting to `enrolledAt` when that item has no entry
    /// for the id. An orphan lastSeen entry for an id absent from the enrolled set is never surfaced
    /// (iterates the enrolled set, not the lastSeen map). Fail-closed to empty on an enrolled-set
    /// read/decode failure (unchanged); a lastSeen read failure no-ops the join (falls back to
    /// `enrolledAt` for everyone) without affecting WHICH clients are returned.
    ///
    /// DELIBERATELY the enrolled set, NOT `authorizedMap()`: a device whose revoke is recorded but not
    /// durably completed (§6d) is unauthorizable yet still enrolled, and must stay VISIBLE so the UI
    /// can offer Retry / Cancel on it (`pendingRevocations()` marks which rows those are). Dropping it
    /// here would strand a wedged revoke with no surface to finish it. Never use `list()` as an
    /// authorization oracle — that is `isAuthorized`/`authorizedClient`.
    public func list() -> [EnrolledClient] {
        let seen = (try? readLastSeenState()) ?? [:]
        return enrolledMap().values.map { entry in
            var joined = entry
            joined.lastSeen = seen[entry.id] ?? entry.enrolledAt
            return joined
        }
    }

    /// The ids of enrolled devices with a DURABLY RECORDED revocation intent (§6d, Sol re-review I5) —
    /// a revoke that started but whose durable removal was never confirmed. Each such device is
    /// unauthorizable (see `authorizedMap()`) while still appearing in `list()`, so the UI renders it
    /// in the "revoke incomplete" state with Retry / an LAContext-gated Cancel — including after a
    /// process restart, where no in-process `RevokeLease` survives. Intersected with the enrolled set
    /// so an inert orphan intent (for a key that is already gone) is never surfaced.
    ///
    /// This is a UI accessor, NOT the gate — but it must not LIE about the gate. An unreadable intent
    /// item is reported as `.unreadable`, never as an empty set: authorization fails closed on that
    /// same read, so "no pending revocations" would be shown at the moment NOTHING is authorized
    /// (Sol re-review, enroll-false-success finding). The caller renders the store-unreadable state
    /// instead of a clean list.
    ///
    /// Also surfaces this process's `unverifiedIntentFence` (N2) — those rows are denied by
    /// `authorizedMap()` too, and a denial the surface cannot see is the same silent lie in a new
    /// costume — but under its OWN tag, never merged into the durable set (Sol pass 4 F1). A merged
    /// set discards the one fact the caller needs to pick a recovery: whether an authenticated REVOKE
    /// was ever requested for the id. It was not, for a fence — its history holds an authenticated
    /// ADMIT — so continuing a "revoke" there would run a destructive durable removal nobody asked
    /// for. What lifts a fence is a discharge (a genuine read of the durable item proving no intent is
    /// pending), which is the same authenticated re-admit hatch `cancelRevocationIntent` provides.
    ///
    /// The two sets are DISJOINT: an id carrying a durably recorded intent is reported as `durable`
    /// even if it also sits in the fence, because the recorded intent is the stronger, restart-surviving
    /// fact — and it is the one that proves a revoke was genuinely requested.
    public func pendingRevocations() -> PendingRevocations {
        guard let intents = revocationIntents() else { return .unreadable }
        guard !intents.isEmpty || !unverifiedIntentFence.isEmpty else {
            return .known(durable: [], enrollmentFenced: [])
        }
        let enrolled = Set(enrolledMap().keys)
        let durable = intents.intersection(enrolled)
        return .known(durable: durable,
                      enrollmentFenced: unverifiedIntentFence.intersection(enrolled).subtracting(durable))
    }

    /// Drop a recorded revocation intent WITHOUT removing the enrollment (§1a step 5 Cancel): the
    /// authenticated escape hatch for a permanently-wedged keychain, deliberately re-admitting the
    /// still-enrolled key. THROWS if the intent item can't be re-read or written, so the caller never
    /// reports a re-admission that didn't durably happen (the device stays fenced instead).
    /// LAContext-gating is the caller's job (`HostAppModel.cancelRevoke`).
    public func cancelRevocationIntent(id: String) throws {
        try dischargeRevocationIntent(id)
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
    ///
    /// Clears any recorded revocation intent for the id AFTER the enrollment write (§6d): an ATTENDED
    /// re-enrollment (LAContext-gated upstream) is an explicit decision to admit the key and supersedes
    /// a pending revocation, so a wedged revoke can never permanently lock out a device the owner just
    /// re-paired in person. Ordered after `persist` on purpose — clearing first and then failing to
    /// write would silently re-admit the key with no enrollment change at all.
    ///
    /// That clear THROWS rather than degrading to best-effort (Sol re-review, enroll-false-success):
    /// `authorizedMap()` subtracts the intent set, and an intent item that cannot be re-read or
    /// re-written leaves the key we just enrolled UNAUTHORIZABLE. A best-effort clear therefore let
    /// `runEnrollmentCeremony` emit `.enrollmentResolved(approved: true)` for a device the gate then
    /// refused — the UI lying about an authorization outcome, the exact class this work exists to
    /// prevent. Failing here is honest and fail-closed: the authorization record stays written (so
    /// the device keeps a visible row the owner can Cancel/repair from) but nobody reports success.
    public func enroll(publicKey: Data, deviceName: String) throws {
        let id = Self.deviceID(forPublicKey: publicKey)
        var state = try mutableState()
        let enrolledAt = state.clients[id]?.enrolledAt ?? now()
        state.clients[id] = EnrolledClient(id: id, publicKey: publicKey, deviceName: deviceName,
                                           enrolledAt: enrolledAt, lastSeen: enrolledAt)
        state.migrationComplete = true  // durable, monotonic: an enrollment ever happened.
        try persist(state)
        do {
            try dischargeRevocationIntent(id)
        } catch {
            // FAIL CLOSED IN THIS PROCESS TOO (Sol pass 3, N2). `persist` above already warmed the
            // authorization cache with this key; if the discharge's own READ threw, a warm
            // `intentCache` from before the failure still answers "nothing pending", so the next
            // handshake would have authorized the very key this call is about to report as failed.
            // The fence makes the thrown error and the gate agree.
            unverifiedIntentFence.insert(id)
            throw PairingStoreError.enrollmentStillFenced(id: id, reason: String(describing: error))
        }
        seedLastSeen(id: id)
    }

    /// Revoke a client. The next handshake's `isAuthorized` returns false → connection closed
    /// pre-scaffolding. A no-op (for the authorization item) if the id wasn't enrolled. Never clears
    /// `migrationComplete` — revoking the last device leaves the gate at `.required`, not reopened.
    /// Also best-effort deletes `lastSeen[id]` from the separate lastSeen item (§6c, H-a) — a
    /// lastSeen failure must not fail the revoke, and doesn't retain the id in the authorization set.
    ///
    /// Records a DURABLE revocation intent FIRST (§6d, Sol re-review I5), before any removal is
    /// attempted, and clears it only once the removal has durably landed. That ordering is what makes
    /// §1a step 5's fail-closed claim true ACROSS A RESTART: `HostControl`'s retained fence and the
    /// app's `revokeFailures` both die with the process, so without the intent a throw here left the
    /// authorization record intact and the next launch silently re-admitted the device. While the
    /// intent is recorded, the id is unauthorizable even though its record still exists.
    ///
    /// Intent recording still does not ABORT the revoke — a broken intent item must not stop the
    /// removal attempt — but its outcome is NO LONGER SWALLOWED (Sol re-review I5 follow-up). When
    /// the removal then fails, the thrown `RevokeIncomplete` says which fence the caller actually
    /// has: `.fencedDurably` (intent recorded → denied across a restart), `.notDurable` (item read,
    /// id absent, write failed → nothing durable landed, this process's in-memory fence is all there
    /// is, and a restart RE-ADMITS the device), or `.durabilityUnknown` (the item could not be read,
    /// so an earlier attempt's durable intent may or may not still be denying the device). The
    /// correlated case — one keychain, so the intent write and the authorization write fail together —
    /// is precisely the one the old best-effort code reported as a clean fenced incomplete. There is
    /// nothing to write when nothing can be written; the fix is to tell the truth about it, and to
    /// re-attempt the intent write on every Retry so a transient failure self-heals into a durable
    /// fence. Collapsing the unknown case into `.notDurable` was the remaining lie (Sol pass 3 N1):
    /// on Retry after a durably-recorded first attempt, a failed READ left `{K}` untouched, so a
    /// fresh process still denies K while the UI announced the opposite.
    ///
    /// Deliberately recorded before the fresh authorization read too, so a revoke that cannot even
    /// READ the authorization item still leaves a durable fence behind.
    public func revoke(id: String) throws {
        let intentDurability = recordRevocationIntent(id)
        var state: Persisted
        do {
            state = try mutableState()
        } catch {
            throw Self.incomplete(intent: intentDurability, underlying: error)
        }
        guard state.clients.removeValue(forKey: id) != nil else {
            // Not enrolled (never was, or another process already removed it): there is nothing to
            // complete, so this is a success and must leave no fence behind — including one this call
            // just recorded, or an inert orphan left by an earlier partial revoke.
            clearRevocationIntent(id)
            return
        }
        do {
            try persist(state)
        } catch {
            throw Self.incomplete(intent: intentDurability, underlying: error)
        }
        clearRevocationIntent(id)
        deleteLastSeen(id: id)
    }

    /// What is durably TRUE about an id's revocation intent once `recordRevocationIntent` has run.
    /// Three states, not two (Sol pass 3, N1): a failed READ proves nothing, and must never be
    /// reported as the proven-absent case.
    enum IntentDurability {
        /// The item was READ and the id is now in it — already present from an earlier attempt, or
        /// this call's write landed. A fresh process denies the id.
        case recorded
        /// The item was READ, the id was NOT in it, and the write FAILED. Nothing durable denies the
        /// id; a restart re-admits it. The only state that may be stated categorically.
        case provenAbsent
        /// The item could not be READ, so nothing was written and nothing is known: a durable intent
        /// from an earlier attempt may or may not be sitting in the item.
        case unknown
    }

    private static func incomplete(intent: IntentDurability, underlying: any Error) -> RevokeIncomplete {
        let reason = String(describing: underlying)
        switch intent {
        case .recorded: return .fencedDurably(reason: reason)
        case .provenAbsent: return .notDurable(reason: reason)
        case .unknown: return .durabilityUnknown(reason: reason)
        }
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

    /// Enrolled (inventory) view: the client map, fail-closed to empty on a read/decode failure.
    /// Does NOT subtract pending revocation intents — that is `authorizedMap()`'s job.
    private func enrolledMap() -> [String: EnrolledClient] {
        readState()?.clients ?? [:]
    }

    /// AUTHORIZATION view: the enrolled map MINUS every id with a recorded revocation intent (§6d)
    /// AND minus every id in this process's `unverifiedIntentFence` (N2). Fail-closed on BOTH items:
    /// an unreadable intent item authorizes nobody, because "no pending revocation" is then
    /// unverifiable — symmetric with an unreadable authorization item, which already denies everyone.
    private func authorizedMap() -> [String: EnrolledClient] {
        guard let intents = revocationIntents() else { return [:] }
        let enrolled = enrolledMap()
        let denied = intents.union(unverifiedIntentFence)
        guard !denied.isEmpty else { return enrolled }
        return enrolled.filter { !denied.contains($0.key) }
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

    /// Mutation view: ALWAYS re-reads the durable item — never the warm cache — and PROPAGATES a read
    /// failure (so a mutation never starts from a partial/empty state and silently drops persisted
    /// entries or the marker). Deliberately ASYMMETRIC with `readState()` above (Sol re-review C2):
    /// returning the warm cache here made every read-modify-write a lost update against an
    /// arbitrarily OLD snapshot — P1 revokes K and writes {J}; P2, still warm on {K, J}, revokes J and
    /// writes {K}, durably RESURRECTING a revoked key while both calls report success. Re-reading
    /// narrows the window to the actual read-modify-write; it does NOT make the RMW atomic (there is
    /// no cross-process CAS on a whole-blob keychain item — bead `portview-auf`, design §9). The
    /// authorization read path keeps its warm cache on purpose: a keychain that locks mid-session must
    /// not brick a live host, and a stale-but-known-good ALLOW there is bounded by the fence + the
    /// durable revocation intent, whereas a stale WRITE here is permanent.
    private func mutableState() throws -> Persisted {
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

    // MARK: - revocation intents (separate keychain item, §6d I5)

    /// Read view for the intent set: cache if warm, else a read that caches only a genuinely
    /// successful decode. Returns nil on a thrown/undecodable read — the authorization path reads that
    /// as "cannot verify → authorize nobody". Warm-caches for the same reason `readState()` does: once
    /// the set has been read successfully, a keychain that locks mid-session must not brick a live host
    /// by denying an already-known device.
    private func revocationIntents() -> Set<String>? {
        if let intentCache { return intentCache }
        do {
            let intents = try readIntentsPersisted()
            intentCache = intents
            return intents
        } catch {
            return nil
        }
    }

    /// Mutation view for the intent set: ALWAYS re-reads the durable item (same C2 rule as
    /// `mutableState`) and propagates failure — writing a lone-entry set built from a stale or empty
    /// snapshot would drop ANOTHER key's pending intent and thereby silently re-admit it.
    private func mutableIntents() throws -> Set<String> {
        let intents = try readIntentsPersisted()
        intentCache = intents
        return intents
    }

    private func readIntentsPersisted() throws -> Set<String> {
        guard let data = try intentStore.read() else { return [] }  // absent item = nothing pending
        return try JSONDecoder().decode(Set<String>.self, from: data)
    }

    private func persistIntents(_ intents: Set<String>) throws {
        try intentStore.write(try JSONEncoder().encode(intents))
        intentCache = intents
    }

    /// Record a revocation intent, REPORTING what is durably true afterwards. Still never throws
    /// upward (a broken intent item must not stop the revoke from attempting the durable removal),
    /// but the outcome is returned rather than swallowed — `revoke` needs it to classify the throw,
    /// and swallowing it is exactly what made a revoke whose intent write AND authorization write both
    /// failed look like a clean fenced incomplete while a restart re-admitted the key. On a read
    /// failure it writes NOTHING — clobbering the set with a lone entry would re-admit every other key
    /// with a pending intent.
    ///
    /// `.recorded` also covers "the id was ALREADY in the durable set" (an earlier attempt recorded
    /// it): the fence is durable, which is the question being asked. A read failure is `.unknown`, NOT
    /// `.provenAbsent` — the durable `{K}` an earlier attempt wrote is untouched by a failed read, so
    /// reporting "nothing durable exists" there is simply false (Sol pass 3, N1).
    private func recordRevocationIntent(_ id: String) -> IntentDurability {
        guard var intents = try? mutableIntents() else { return .unknown }
        guard intents.insert(id).inserted else { return .recorded }
        do { try persistIntents(intents) } catch { return .provenAbsent }
        return .recorded
    }

    /// Durably drop `id` from the intent set, THROWING if the set cannot be re-read or the write
    /// fails. The single implementation behind the public Cancel hatch, `enroll`'s mandatory clear,
    /// and the best-effort `clearRevocationIntent` below — the three differ only in how they treat a
    /// failure, never in what they attempt.
    ///
    /// Reaching the end is the ONLY thing that lifts `unverifiedIntentFence` for the id (N2): it means
    /// the durable item was genuinely READ and the id is verifiably not pending in it, which is
    /// precisely the fact the fence stands in for when it cannot be established.
    private func dischargeRevocationIntent(_ id: String) throws {
        var intents = try mutableIntents()
        if intents.remove(id) != nil {
            try persistIntents(intents)
        }
        unverifiedIntentFence.remove(id)
    }

    /// Best-effort intent clear, used ONLY where the intent is already discharged by the durable
    /// removal itself (the removal landed, or the id is not enrolled). A failed clear leaves an inert
    /// ORPHAN: the id is not enrolled, so it authorizes nobody, and `pendingRevocations()` filters it
    /// out — but the orphan is real and is NOT swept, so a successful revoke does not guarantee "no
    /// intent left" (design §10 R11). It is discharged by the next `enroll`/`revoke` of that id, and
    /// `enroll` now THROWS if it cannot, rather than reporting a success the gate would refuse.
    private func clearRevocationIntent(_ id: String) {
        try? dischargeRevocationIntent(id)
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

/// Keychain-backed store for the SEPARATE pending-revocation-intent item (§6d, Sol re-review I5): a
/// distinct `service` from both the authorization item and the lastSeen item, holding the encoded
/// `Set<ClientKeyID>` of revocations that were STARTED but whose durable removal has not been
/// confirmed. Its own item (rather than a field inside the authorization blob) for the same reason
/// the lastSeen split exists: an intent write must never be a read-modify-write of the authorization
/// set, so recording an intent can never resurrect or drop an enrolled key. Same device-only
/// accessibility; mirrors `KeychainPairingStore`.
struct KeychainRevokeIntentStore: PairingRecordStore {
    private let service = "dev.finklea.portview.pairings.revokeintents"
    private let account = "pending-revocations"

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

/// Ephemeral in-memory fallback for the `lastSeenStore` / `revokeIntentStore` seams — the default
/// for call sites that predate the lastSeen split (§6c, H-a) or the revocation-intent item (§6d, I5)
/// and inject neither. Never persisted, never shared across instances.
private final class EphemeralPairingRecordStore: PairingRecordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var blob: Data?
    func read() throws -> Data? { lock.lock(); defer { lock.unlock() }; return blob }
    func write(_ data: Data) throws { lock.lock(); defer { lock.unlock() }; blob = data }
}

enum PairingStoreError: Error {
    case keychainError(OSStatus)
    /// `enroll` persisted the authorization record but could NOT durably verify that the key is free
    /// of a pending revocation intent — so the key it just enrolled is not authorizable and the
    /// enrollment must not be reported as a success (Sol re-review, enroll-false-success finding).
    case enrollmentStillFenced(id: String, reason: String)
}

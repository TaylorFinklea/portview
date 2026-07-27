// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import CryptoKit
import PortviewProtocol
@testable import PortviewTransport

/// The host-side revocable PairingStore (mutual-auth spec §2). The invariant that matters most:
/// `isAuthorized` fails CLOSED — unlike the TLS identity store's deliberate degrade-to-ephemeral,
/// an authorization gate must treat any read/decode failure or absent map as "nobody authorized."
@Suite struct PairingStoreTests {
    /// In-memory `PairingRecordStore` for tests; can be told to throw to simulate a locked/corrupt
    /// keychain.
    private final class MemoryStore: PairingRecordStore, @unchecked Sendable {
        private let lock = NSLock()
        private var blob: Data?
        var failRead = false
        var failWrite = false
        private(set) var writeCount = 0

        init(_ blob: Data? = nil) { self.blob = blob }

        func read() throws -> Data? {
            lock.lock(); defer { lock.unlock() }
            if failRead { throw TestStoreError.injected }
            return blob
        }
        func write(_ data: Data) throws {
            lock.lock(); defer { lock.unlock() }
            if failWrite { throw TestStoreError.injected }
            blob = data
            writeCount += 1
        }
        func rawBlob() -> Data? { lock.lock(); defer { lock.unlock() }; return blob }
    }
    private enum TestStoreError: Error { case injected }

    /// In-memory `PairingRecordStore` for the SEPARATE lastSeen item (§6c, han.4 H-a); mirrors
    /// `MemoryStore` above. Adds an optional read-pause hook — armed only by the cross-process
    /// barrier test — to deterministically interleave a concurrent auth-store mutation between a
    /// `touch`'s lastSeen read and its lastSeen write.
    private final class MemoryLastSeenStore: PairingRecordStore, @unchecked Sendable {
        private let lock = NSLock()
        private var blob: Data?
        var failRead = false
        var failWrite = false
        private(set) var writeCount = 0
        private var pauseNextRead = false
        private let readPaused = DispatchSemaphore(value: 0)
        private let resumeReadSignal = DispatchSemaphore(value: 0)

        init(_ blob: Data? = nil) { self.blob = blob }

        /// Arms a ONE-SHOT pause: the next `read()` call snapshots the blob, signals
        /// `waitUntilReadPaused()`, then blocks until `continueRead()` is called — all with the
        /// lock released, so a concurrent `read()`/`write()` from another store user is never
        /// blocked by the pause itself. Deliberately UNBOUNDED waits (mirrors the plain
        /// `DispatchSemaphore.wait()` used by `InboundBufferTests`' barrier tests): by program
        /// order, nothing else can call `read()` between `armPauseOnNextRead()` and the intended
        /// `touch`'s read, so this can only be satisfied by that read — a bounded timeout risks
        /// firing under severe parallel-suite load and letting a LATER caller's read become the
        /// one that pauses instead, corrupting the intended interleaving.
        func armPauseOnNextRead() { lock.lock(); pauseNextRead = true; lock.unlock() }
        func waitUntilReadPaused() { readPaused.wait() }
        func continueRead() { resumeReadSignal.signal() }

        func read() throws -> Data? {
            lock.lock()
            if failRead { lock.unlock(); throw TestStoreError.injected }
            let snapshot = blob
            let shouldPause = pauseNextRead
            if shouldPause { pauseNextRead = false }
            lock.unlock()
            if shouldPause {
                readPaused.signal()
                resumeReadSignal.wait()
            }
            return snapshot
        }
        func write(_ data: Data) throws {
            lock.lock(); defer { lock.unlock() }
            if failWrite { throw TestStoreError.injected }
            blob = data
            writeCount += 1
        }
        func rawBlob() -> Data? { lock.lock(); defer { lock.unlock() }; return blob }
    }

    /// A fresh client keypair: returns its raw public key and the id the store must derive for it.
    private func newClient() -> (publicKey: Data, id: String) {
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        return (key, PairingStore.deviceID(forPublicKey: key))
    }

    @Test func enrollThenAuthorized() async {
        let store = MemoryStore()
        let pairing = PairingStore(store: store, now: { Date(timeIntervalSince1970: 2000) })
        let c = newClient()
        try? await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")
        #expect(await pairing.isAuthorized(id: c.id) == true)
        #expect(await pairing.isAuthorized(id: "not-enrolled") == false)
    }

    @Test func idIsDerivedFromKeyNotCallerSupplied() async {
        // The store derives id = SHA256(publicKey); a caller cannot enroll a key under an id that
        // doesn't match it, and lookup by the presented key requires exact stored-key equality.
        let store = MemoryStore()
        let pairing = PairingStore(store: store, now: { Date(timeIntervalSince1970: 2000) })
        let c = newClient()
        try? await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")
        #expect(await pairing.deviceID(forPublicKey: c.publicKey) == c.id)
        #expect(await pairing.authorizedClient(forPublicKey: c.publicKey)?.id == c.id)
        // A different key with no enrollment is not authorized even though ids are just map keys.
        let other = newClient()
        #expect(await pairing.authorizedClient(forPublicKey: other.publicKey) == nil)
    }

    @Test func revokeMakesUnauthorized() async {
        let store = MemoryStore()
        let pairing = PairingStore(store: store, now: { Date(timeIntervalSince1970: 2000) })
        let c = newClient()
        try? await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")
        try? await pairing.revoke(id: c.id)
        #expect(await pairing.isAuthorized(id: c.id) == false)
        #expect(await pairing.authorizedClient(forPublicKey: c.publicKey) == nil)
    }

    @Test func listReflectsEnrollAndRevoke() async {
        let store = MemoryStore()
        let pairing = PairingStore(store: store, now: { Date(timeIntervalSince1970: 2000) })
        let a = newClient()
        let b = newClient()
        try? await pairing.enroll(publicKey: a.publicKey, deviceName: "A")
        try? await pairing.enroll(publicKey: b.publicKey, deviceName: "B")
        #expect(Set(await pairing.list().map(\.id)) == Set([a.id, b.id]))
        try? await pairing.revoke(id: a.id)
        #expect(await pairing.list().map(\.id) == [b.id])
    }

    @Test func persistsThroughTheStore() async {
        let store = MemoryStore()
        let c = newClient()
        let first = PairingStore(store: store, now: { Date(timeIntervalSince1970: 2000) })
        try? await first.enroll(publicKey: c.publicKey, deviceName: "iPhone")
        // A fresh actor over the SAME backing store sees the enrollment (persisted, not just cached).
        let second = PairingStore(store: store, now: { Date(timeIntervalSince1970: 3000) })
        #expect(await second.isAuthorized(id: c.id) == true)
    }

    @Test func absentMapAuthorizesNobody() async {
        let store = MemoryStore(nil)  // nothing ever written
        let pairing = PairingStore(store: store, now: { Date(timeIntervalSince1970: 2000) })
        #expect(await pairing.isAuthorized(id: "anything") == false)
        #expect(await pairing.list().isEmpty)
    }

    @Test func readFailureFailsClosed() async {
        let store = MemoryStore()
        let pairing = PairingStore(store: store, now: { Date(timeIntervalSince1970: 2000) })
        store.failRead = true
        // No successful read has populated the cache → a throwing store must deny, not admit.
        #expect(await pairing.isAuthorized(id: "anything") == false)
        #expect(await pairing.list().isEmpty)
    }

    @Test func corruptBlobFailsClosed() async {
        let store = MemoryStore(Data([0xDE, 0xAD, 0xBE, 0xEF]))  // not decodable JSON map
        let pairing = PairingStore(store: store, now: { Date(timeIntervalSince1970: 2000) })
        #expect(await pairing.isAuthorized(id: "anything") == false)
    }

    @Test func bootstrapNeverReopensAfterRevokingAllDevices() async throws {
        // Sol han.1 review (CRITICAL): the durable "migration complete" marker. Once a device has
        // EVER enrolled, revoking the last one must NOT return the store to `.empty` (which would
        // reopen the legacy bootstrap to any silent peer). The map is empty but the snapshot stays
        // `.populated` — the host stays fail-closed to `.required` until a re-attended enrollment.
        let store = MemoryStore()
        let pairing = PairingStore(store: store, now: { Date(timeIntervalSince1970: 2000) })
        let c = newClient()
        try await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")
        #expect(await pairing.enrollmentSnapshot() == .populated)
        try await pairing.revoke(id: c.id)
        #expect(await pairing.list().isEmpty)                    // no devices authorized
        #expect(await pairing.enrollmentSnapshot() == .populated) // but migration is permanent
    }

    @Test func migrationMarkerPersistsAcrossReload() async throws {
        // The marker is durable, not just in-memory: a fresh actor over the same backing store (a
        // host restart) reads migration-complete even after every device was revoked.
        let store = MemoryStore()
        let first = PairingStore(store: store, now: { Date(timeIntervalSince1970: 2000) })
        let c = newClient()
        try await first.enroll(publicKey: c.publicKey, deviceName: "iPhone")
        try await first.revoke(id: c.id)

        let reloaded = PairingStore(store: store, now: { Date(timeIntervalSince1970: 2000) })
        #expect(await reloaded.enrollmentSnapshot() == .populated)
        #expect(await reloaded.list().isEmpty)
    }

    @Test func legacyBareMapBlobStillDecodes() async throws {
        // Back-compat: a store written by the han.2-era format (a bare `[id: EnrolledClient]` map,
        // no wrapper) must still decode. A non-empty legacy map implies migration already happened.
        let c = newClient()
        let legacy = [c.id: EnrolledClient(id: c.id, publicKey: c.publicKey, deviceName: "old",
                                           enrolledAt: Date(timeIntervalSince1970: 1000),
                                           lastSeen: Date(timeIntervalSince1970: 1000))]
        let store = MemoryStore(try JSONEncoder().encode(legacy))
        let pairing = PairingStore(store: store, now: { Date(timeIntervalSince1970: 2000) })
        #expect(await pairing.isAuthorized(id: c.id) == true)
        #expect(await pairing.enrollmentSnapshot() == .populated)
    }

    @Test func enrollmentSnapshotDistinguishesEmptyPopulatedUnreadable() async throws {
        // The rollout-policy view (Sol han.1 review): unlike `list()`/`isAuthorized` which fail
        // closed to EMPTY, this must surface an unreadable store as `.unreadable` so the policy can
        // fail closed to `.required` instead of reopening bootstrap.
        let empty = PairingStore(store: MemoryStore(), now: { Date(timeIntervalSince1970: 2000) })
        #expect(await empty.enrollmentSnapshot() == .empty)

        let populated = PairingStore(store: MemoryStore(), now: { Date(timeIntervalSince1970: 2000) })
        try await populated.enroll(publicKey: newClient().publicKey, deviceName: "iPhone")
        #expect(await populated.enrollmentSnapshot() == .populated)

        let store = MemoryStore()
        let unreadable = PairingStore(store: store, now: { Date(timeIntervalSince1970: 2000) })
        store.failRead = true  // cold cache + throwing read → not verifiably empty
        #expect(await unreadable.enrollmentSnapshot() == .unreadable)
    }

    @Test func cachedMapSurvivesAKeychainThatLocksMidSession() async {
        let store = MemoryStore()
        let pairing = PairingStore(store: store, now: { Date(timeIntervalSince1970: 2000) })
        let c = newClient()
        try? await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")
        _ = await pairing.isAuthorized(id: c.id)  // populate cache with a good read
        store.failRead = true                      // keychain locks after unlock-at-launch
        // A live host keeps authorizing its already-known device from the in-memory cache.
        #expect(await pairing.isAuthorized(id: c.id) == true)
    }

    @Test func enrollDoesNotClobberOnColdCacheReadFailure() async throws {
        // `a` is already persisted, but a FRESH actor hasn't read it yet (cold cache). If a read
        // failure during enroll silently started from an empty map, it would persist `[b]` and
        // drop `a`. Enroll must surface the error instead and leave the store untouched.
        let aKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let aID = PairingStore.deviceID(forPublicKey: aKey)
        let a = EnrolledClient(id: aID, publicKey: aKey, deviceName: "A",
                               enrolledAt: Date(timeIntervalSince1970: 1000),
                               lastSeen: Date(timeIntervalSince1970: 1000))
        let seeded = try JSONEncoder().encode([aID: a])
        let store = MemoryStore(seeded)
        let pairing = PairingStore(store: store, now: { Date(timeIntervalSince1970: 2000) })
        store.failRead = true
        let b = newClient()
        await #expect(throws: (any Error).self) {
            try await pairing.enroll(publicKey: b.publicKey, deviceName: "B")
        }
        // Nothing was written; a fresh actor over the store still sees exactly `a`.
        store.failRead = false
        let fresh = PairingStore(store: store, now: { Date(timeIntervalSince1970: 3000) })
        #expect(await fresh.isAuthorized(id: aID) == true)
        #expect(await fresh.isAuthorized(id: b.id) == false)
    }

    @Test func touchUpdatesLastSeen() async {
        let store = MemoryStore()
        let pairing = PairingStore(store: store, now: { Date(timeIntervalSince1970: 5000) })
        let c = newClient()
        try? await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")
        try? await pairing.touch(id: c.id)
        let seen = await pairing.list().first?.lastSeen
        #expect(seen == Date(timeIntervalSince1970: 5000))
    }

    @Test func fingerprintIsPrefixOfDeviceID() {
        // KeyFingerprint (han.3, shared human-compare view) and PairingStore.deviceID both derive
        // from SHA256(publicKey); the fingerprint's hex (stripped of grouping spaces, lowercased)
        // must equal the leading 20 hex chars of the full device id.
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let fingerprint = KeyFingerprint.short(forPublicKey: key)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        #expect(fingerprint == String(PairingStore.deviceID(forPublicKey: key).prefix(20)))
    }

    @Test func reEnrollUpdatesNameKeepsEnrolledAt() async {
        let store = MemoryStore()
        let pairing = PairingStore(store: store, now: { Date(timeIntervalSince1970: 2000) })
        let c = newClient()
        try? await pairing.enroll(publicKey: c.publicKey, deviceName: "Old Name")
        let firstEnrolledAt = await pairing.list().first?.enrolledAt
        try? await pairing.enroll(publicKey: c.publicKey, deviceName: "New Name")
        let entries = await pairing.list()
        #expect(entries.count == 1)
        #expect(entries.first?.deviceName == "New Name")
        #expect(entries.first?.enrolledAt == firstEnrolledAt)  // enrolledAt preserved across re-enroll
    }

    // MARK: - mutations re-read the durable item (Sol re-review C2)

    @Test func staleWarmCacheCannotResurrectAKeyRevokedByAnotherInstance() async throws {
        // Two PairingStore actors over ONE backing item — the app/CLI shape, or two windows of the
        // same process. Both warm their caches with {K, J}. Instance A revokes K (durable = {J}).
        // Instance B — still warm and now STALE — revokes J. If B's read-modify-write started from
        // its warm snapshot it would persist {K}, durably RESURRECTING a revoked key while both
        // calls reported success. The mutation path must re-read the durable item first.
        let shared = MemoryStore()
        let instanceA = PairingStore(store: shared, now: { Date(timeIntervalSince1970: 2000) })
        let instanceB = PairingStore(store: shared, now: { Date(timeIntervalSince1970: 2000) })
        let k = newClient()
        let j = newClient()
        try await instanceA.enroll(publicKey: k.publicKey, deviceName: "K")
        try await instanceA.enroll(publicKey: j.publicKey, deviceName: "J")
        #expect(await instanceB.isAuthorized(id: k.id) == true)  // warms B's cache with {K, J}
        #expect(await instanceB.isAuthorized(id: j.id) == true)

        try await instanceA.revoke(id: k.id)  // durable set is now {J}
        try await instanceB.revoke(id: j.id)  // B is warm+stale; must re-read, not clobber

        let restarted = PairingStore(store: shared, now: { Date(timeIntervalSince1970: 3000) })
        #expect(await restarted.isAuthorized(id: k.id) == false)  // K must stay revoked
        #expect(await restarted.isAuthorized(id: j.id) == false)
        #expect(await restarted.list().isEmpty)
    }

    @Test func staleWarmCacheCannotResurrectARevokedKeyOnEnroll() async throws {
        // Same lost update via the OTHER mutation: an unrelated enroll from the stale instance
        // re-persisted the whole map, bringing the revoked key back with it.
        let shared = MemoryStore()
        let instanceA = PairingStore(store: shared, now: { Date(timeIntervalSince1970: 2000) })
        let instanceB = PairingStore(store: shared, now: { Date(timeIntervalSince1970: 2000) })
        let k = newClient()
        let x = newClient()
        try await instanceA.enroll(publicKey: k.publicKey, deviceName: "K")
        #expect(await instanceB.isAuthorized(id: k.id) == true)  // warms B's cache with {K}

        try await instanceA.revoke(id: k.id)
        try await instanceB.enroll(publicKey: x.publicKey, deviceName: "X")

        let restarted = PairingStore(store: shared, now: { Date(timeIntervalSince1970: 3000) })
        #expect(await restarted.isAuthorized(id: k.id) == false)  // not resurrected by B's enroll
        #expect(await restarted.isAuthorized(id: x.id) == true)
    }

    @Test func mutationPropagatesAReadFailureEvenWithAWarmCache() async throws {
        // The deliberate ASYMMETRY: the mutation path must fail rather than write from a snapshot it
        // cannot re-verify, while the AUTHORIZATION read path keeps serving its warm cache so a
        // keychain that locks mid-session cannot brick a live host.
        let store = MemoryStore()
        let pairing = PairingStore(store: store, now: { Date(timeIntervalSince1970: 2000) })
        let c = newClient()
        let d = newClient()
        try await pairing.enroll(publicKey: c.publicKey, deviceName: "C")
        try await pairing.enroll(publicKey: d.publicKey, deviceName: "D")
        #expect(await pairing.isAuthorized(id: d.id) == true)  // cache is warm
        store.failRead = true

        await #expect(throws: (any Error).self) {
            try await pairing.enroll(publicKey: self.newClient().publicKey, deviceName: "E")
        }
        await #expect(throws: (any Error).self) { try await pairing.revoke(id: c.id) }
        // Read path unchanged: still authorizes a known device from the warm cache.
        #expect(await pairing.isAuthorized(id: d.id) == true)
    }

    // MARK: - durable revocation intent (§6d, Sol re-review I5): fail-closed across a RESTART

    /// THE decisive restart test. `beginRevoke`'s in-process fence and `HostAppModel.revokeFailures`
    /// both die with the process, so before the intent item a failed durable revoke meant: the user
    /// revoked, the UI said "incomplete", the app was quit, and the next launch silently re-admitted
    /// the still-enrolled device at generation 0. A FRESH store instance (= the next process) must
    /// refuse to authorize a key whose revocation was recorded but never durably completed.
    @Test func recordedRevocationIntentSurvivesARestartAndFailsClosed() async throws {
        let auth = MemoryStore()
        let intents = MemoryStore()
        let pairing = PairingStore(store: auth, revokeIntentStore: intents,
                                   now: { Date(timeIntervalSince1970: 2000) })
        let c = newClient()
        try await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")

        auth.failWrite = true  // the durable removal throws — the record stays in the item
        var thrown: (any Error)?
        do { try await pairing.revoke(id: c.id) } catch { thrown = error }
        // The intent item is healthy here, so the failure must report the DURABLE fence — the case
        // that is genuinely safe across a restart (contrast:
        // `revokeSurfacesANonDurableFenceWhenTheIntentWriteAlsoFails`).
        #expect(try #require(thrown as? RevokeIncomplete).isDurablyFenced == true)
        auth.failWrite = false
        #expect(await pairing.isAuthorized(id: c.id) == false)  // fenced in this process too

        // A fresh instance over the same items = the next process launch: no in-memory fence, no
        // retained lease, the authorization record still present.
        let restarted = PairingStore(store: auth, lastSeenStore: MemoryLastSeenStore(),
                                     revokeIntentStore: intents,
                                     now: { Date(timeIntervalSince1970: 3000) })
        #expect(await restarted.isAuthorized(id: c.id) == false)
        #expect(await restarted.authorizedClient(forPublicKey: c.publicKey) == nil)
        // ...but the device is still ENROLLED, so the UI can still show it in the incomplete state
        // with Retry / Cancel (the row must not vanish — that would strand the wedged revoke).
        #expect(await restarted.list().map(\.id) == [c.id])
    }

    /// Decodes the DURABLE intent blob straight out of the injected item. Every "…leaves no intent
    /// behind" assertion goes through this rather than through a re-enroll: `enroll` clears the intent
    /// itself, so a re-enroll-based assertion passes even when the mechanism under test never ran
    /// (Sol re-review, test-honesty finding). An item that was never written decodes as empty.
    private func durableIntents(_ store: MemoryStore) throws -> Set<String> {
        guard let raw = store.rawBlob() else { return [] }
        return try JSONDecoder().decode(Set<String>.self, from: raw)
    }

    @Test func retryAfterARestartCompletesTheRevokeAndClearsTheIntent() async throws {
        let auth = MemoryStore()
        let intents = MemoryStore()
        let pairing = PairingStore(store: auth, revokeIntentStore: intents,
                                   now: { Date(timeIntervalSince1970: 2000) })
        let c = newClient()
        try await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")
        auth.failWrite = true
        await #expect(throws: (any Error).self) { try await pairing.revoke(id: c.id) }
        auth.failWrite = false

        // Restart. Check the restarted store BEFORE the Retry: without the durable intent mechanism
        // this fresh instance would happily authorize K (its record is still in the auth item and no
        // in-process fence survived), so these two assertions are what make the test require the
        // mechanism at all — the post-Retry ones pass with or without it.
        let restarted = PairingStore(store: auth, revokeIntentStore: intents,
                                     now: { Date(timeIntervalSince1970: 3000) })
        #expect(await restarted.isAuthorized(id: c.id) == false)
        #expect(await restarted.pendingRevocations() == .known(durable: [c.id], enrollmentFenced: []))

        // Retry WITHOUT a lease (there is none to reuse in a fresh process).
        try await restarted.revoke(id: c.id)
        #expect(await restarted.isAuthorized(id: c.id) == false)
        #expect(await restarted.list().isEmpty)
        // The completed revoke left NO intent behind — read from the durable item, NOT inferred from
        // a re-enroll (which would clear the intent itself and mask a lingering one).
        #expect(try durableIntents(intents).isEmpty)
    }

    @Test func successfulRevokeLeavesNoIntentBehind() async throws {
        let auth = MemoryStore()
        let intents = MemoryStore()
        let pairing = PairingStore(store: auth, revokeIntentStore: intents,
                                   now: { Date(timeIntervalSince1970: 2000) })
        let c = newClient()
        try await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")
        try await pairing.revoke(id: c.id)
        // Direct evidence from the DURABLE intent item: `revoke` recorded an intent on entry and must
        // have discharged it. Deliberately NOT a re-enroll assertion — `enroll` clears the intent, so
        // that version passed even when `revoke` never cleared anything.
        #expect(try durableIntents(intents).isEmpty)
        // ...and a fresh instance (cold intent cache) reads the same empty set.
        let restarted = PairingStore(store: auth, revokeIntentStore: intents,
                                     now: { Date(timeIntervalSince1970: 3000) })
        #expect(await restarted.pendingRevocations() == .known(durable: [], enrollmentFenced: []))
    }

    @Test func attendedReEnrollClearsAStaleRevocationIntent() async throws {
        // The wedged-revoke escape valve that needs no new UI: an ATTENDED re-enrollment of the same
        // key (LAContext-gated upstream) supersedes a pending intent. Without this an orphaned intent
        // would permanently lock out a device the owner just re-paired in person.
        let auth = MemoryStore()
        let intents = MemoryStore()
        let pairing = PairingStore(store: auth, revokeIntentStore: intents,
                                   now: { Date(timeIntervalSince1970: 2000) })
        let c = newClient()
        try await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")
        auth.failWrite = true
        await #expect(throws: (any Error).self) { try await pairing.revoke(id: c.id) }
        auth.failWrite = false
        #expect(await pairing.isAuthorized(id: c.id) == false)

        try await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")
        #expect(await pairing.isAuthorized(id: c.id) == true)
        let restarted = PairingStore(store: auth, revokeIntentStore: intents,
                                     now: { Date(timeIntervalSince1970: 3000) })
        #expect(await restarted.isAuthorized(id: c.id) == true)  // the clear was durable
    }

    @Test func intentWriteFailureStillAttemptsTheDurableRemoval() async throws {
        // "If writing the intent itself fails, proceed with the attempt anyway — that is no worse
        // than today — but do not report a false success." Here the removal SUCCEEDS, so the revoke
        // is genuinely complete and must report success.
        let auth = MemoryStore()
        let intents = MemoryStore()
        intents.failWrite = true
        let pairing = PairingStore(store: auth, revokeIntentStore: intents,
                                   now: { Date(timeIntervalSince1970: 2000) })
        let c = newClient()
        try await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")
        try await pairing.revoke(id: c.id)  // must NOT throw: the durable removal landed
        #expect(await pairing.isAuthorized(id: c.id) == false)
        let restarted = PairingStore(store: auth, revokeIntentStore: intents,
                                     now: { Date(timeIntervalSince1970: 3000) })
        #expect(await restarted.isAuthorized(id: c.id) == false)
    }

    /// THE honest I5 regression (Sol re-review). When the intent write AND the authorization write
    /// both fail — the natural CORRELATED case, since both items live in the same keychain — nothing
    /// durable was recorded and a host restart re-admits the device. No implementation can deny from
    /// a cold store when nothing could be written, so the contract is that `revoke` must SAY SO:
    /// `.notDurable`, distinguishable from the `.fencedDurably` it reports when the intent landed.
    /// Reporting a clean fenced-incomplete here is the false assurance the intent item exists to kill.
    @Test func revokeSurfacesANonDurableFenceWhenTheIntentWriteAlsoFails() async throws {
        let auth = MemoryStore()
        let intents = MemoryStore()
        let pairing = PairingStore(store: auth, revokeIntentStore: intents,
                                   now: { Date(timeIntervalSince1970: 2000) })
        let c = newClient()
        try await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")

        intents.failWrite = true  // the intent cannot be recorded...
        auth.failWrite = true     // ...and neither can the removal (one keychain, correlated failure)
        var thrown: (any Error)?
        do { try await pairing.revoke(id: c.id) } catch { thrown = error }
        #expect(try #require(thrown as? RevokeIncomplete).isDurablyFenced == false)
        intents.failWrite = false
        auth.failWrite = false

        // ...and the report is TRUE, which is why it has to be surfaced: nothing durable exists, so a
        // fresh process re-admits the device. This assertion documents the honest residual — the fix
        // is the loud report + the self-healing Retry below, not a denial that cannot be persisted.
        #expect(try durableIntents(intents).isEmpty)
        let restarted = PairingStore(store: auth, revokeIntentStore: intents,
                                     now: { Date(timeIntervalSince1970: 3000) })
        #expect(await restarted.isAuthorized(id: c.id) == true)
    }

    /// Sol pass 3, N1: a failed intent READ is UNKNOWN durability, never PROVEN absence. The
    /// counterexample the old two-state report got wrong: an earlier attempt durably recorded K's
    /// intent and failed only the authorization removal (`.fencedDurably`); on Retry the intent read
    /// throws, so nothing is written and the durable `{K}` blob is untouched — yet `revoke` reported
    /// `.notDurable`, whose whole meaning is "a restart re-admits this device". A fresh process still
    /// denies K, so that report was simply false.
    @Test func aFailedIntentReadReportsUnknownDurabilityNotProvenAbsence() async throws {
        let auth = MemoryStore()
        let intents = MemoryStore()
        let pairing = PairingStore(store: auth, revokeIntentStore: intents,
                                   now: { Date(timeIntervalSince1970: 2000) })
        let c = newClient()
        try await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")

        // First attempt: the intent lands, only the removal fails.
        auth.failWrite = true
        var first: (any Error)?
        do { try await pairing.revoke(id: c.id) } catch { first = error }
        #expect(try #require(first as? RevokeIncomplete).isDurablyFenced == true)
        #expect(try durableIntents(intents) == [c.id])

        // Retry: now the intent item cannot even be READ. Nothing is written, so `{K}` is untouched.
        intents.failRead = true
        var second: (any Error)?
        do { try await pairing.revoke(id: c.id) } catch { second = error }
        let outcome = try #require(second as? RevokeIncomplete)
        var reportedUnknown = false
        if case .durabilityUnknown = outcome { reportedUnknown = true }
        #expect(reportedUnknown, "expected .durabilityUnknown, got \(outcome)")
        #expect(outcome.isDurablyFenced == false)       // unproven is not proven …
        #expect(outcome.isProvenNotDurable == false)    // … but it is not proven absent either
        intents.failRead = false
        auth.failWrite = false

        // And the reason the categorical copy would have been a lie: the durable fence is still there.
        #expect(try durableIntents(intents) == [c.id])
        let restarted = PairingStore(store: auth, revokeIntentStore: intents,
                                     now: { Date(timeIntervalSince1970: 3000) })
        #expect(await restarted.isAuthorized(id: c.id) == false)
        #expect(await restarted.pendingRevocations() == .known(durable: [c.id], enrollmentFenced: []))
    }

    /// Sol pass 3, N2: a FAILED enrollment must not leave an authorizable key in THIS process. The
    /// interleaving the existing tests missed — they cover a cache already holding K's intent, and a
    /// COLD corrupt item — is a WARM-EMPTY `intentCache` plus an intent item that becomes unreadable:
    /// `enroll` persists K (warming the authorization cache), its fresh intent read throws, and it
    /// throws `enrollmentStillFenced` — but the still-warm `[]` intent cache answers "nothing
    /// pending", so the next signed handshake admitted the key the ceremony had just reported as
    /// `approved: false`.
    @Test func aFailedEnrollLeavesTheKeyUnauthorizableEvenWithAWarmEmptyIntentCache() async throws {
        let auth = MemoryStore()
        let intents = MemoryStore()
        let pairing = PairingStore(store: auth, revokeIntentStore: intents,
                                   now: { Date(timeIntervalSince1970: 2000) })
        let seed = newClient()
        try await pairing.enroll(publicKey: seed.publicKey, deviceName: "Seed iPhone")
        #expect(await pairing.isAuthorized(id: seed.id) == true)  // warms the intent cache to []

        // The intent item goes unreadable while the authorization item stays writable.
        intents.failRead = true
        let c = newClient()
        await #expect(throws: (any Error).self) {
            try await pairing.enroll(publicKey: c.publicKey, deviceName: "iPad")
        }
        // The authorization record IS written (the clear is ordered after `persist`) …
        #expect(await pairing.list().map(\.id).sorted() == [seed.id, c.id].sorted())
        // … and the key the operation reported as FAILED must not be authorizable here, even though
        // the warm intent cache still says nothing is pending for it.
        #expect(await pairing.isAuthorized(id: c.id) == false)
        #expect(await pairing.authorizedClient(forPublicKey: c.publicKey) == nil)
        // The other device is untouched: the fence is per-id, not a wholesale cache poisoning that
        // would brick a live host on a transient keychain lock.
        #expect(await pairing.isAuthorized(id: seed.id) == true)

        // The fence outlives the transient failure: a later successful read that simply OMITS the key
        // must not re-admit what the failed enrollment already reported as refused.
        intents.failRead = false
        #expect(await pairing.isAuthorized(id: c.id) == false)
        // The denial is VISIBLE — and visible AS WHAT IT IS (Sol pass 4 F1). The fence must arrive
        // under `enrollmentFenced`, never merged into `durable`: the durable tag means "an
        // authenticated revoke was requested and recorded", which is false here (the only decision in
        // this key's history is an ADMIT), and the app routes a durable-tagged row to a Retry that
        // runs a destructive `revoke`.
        #expect(await pairing.pendingRevocations() == .known(durable: [], enrollmentFenced: [c.id]))
        // …and nothing durable was in fact recorded for it, which is what makes the tag load-bearing
        // rather than cosmetic.
        #expect(try durableIntents(intents).isEmpty)
        // Only a discharge that genuinely READS the durable item lifts it — the attended Cancel hatch.
        try await pairing.cancelRevocationIntent(id: c.id)
        #expect(await pairing.isAuthorized(id: c.id) == true)
        #expect(await pairing.pendingRevocations() == .known(durable: [], enrollmentFenced: []))
    }

    /// The disjointness rule (Sol pass 4 F1): when an id carries BOTH a durably recorded intent and
    /// this process's enrollment fence, it is reported as `durable` only. The durable tag is the
    /// stronger fact — it survives a restart AND it proves an authenticated revoke was requested — so
    /// the row correctly stays a revoke row, and the two sets never double-count a device.
    @Test func aDurablyRecordedIntentOutranksTheEnrollmentFenceForTheSameKey() async throws {
        let auth = MemoryStore()
        let intents = MemoryStore()
        let pairing = PairingStore(store: auth, revokeIntentStore: intents,
                                   now: { Date(timeIntervalSince1970: 2000) })
        let c = newClient()
        try await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")

        // A revoke wedges: the intent IS durably recorded, the removal is not.
        auth.failWrite = true
        await #expect(throws: (any Error).self) { try await pairing.revoke(id: c.id) }
        auth.failWrite = false
        #expect(try durableIntents(intents) == [c.id])

        // An attended re-enroll of the same key now fails its discharge read → it also lands in the
        // process fence, so the id is in BOTH sources.
        intents.failRead = true
        await #expect(throws: (any Error).self) {
            try await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")
        }
        intents.failRead = false
        #expect(await pairing.isAuthorized(id: c.id) == false)
        #expect(await pairing.pendingRevocations() == .known(durable: [c.id], enrollmentFenced: []))
    }

    /// Ruling item 2: Retry must RE-ATTEMPT the intent write, so a transient keychain failure heals
    /// into a durable fence instead of staying non-durable until the app quits.
    @Test func retryRecordsTheIntentTheFirstAttemptCouldNotWrite() async throws {
        let auth = MemoryStore()
        let intents = MemoryStore()
        let pairing = PairingStore(store: auth, revokeIntentStore: intents,
                                   now: { Date(timeIntervalSince1970: 2000) })
        let c = newClient()
        try await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")

        intents.failWrite = true
        auth.failWrite = true
        var first: (any Error)?
        do { try await pairing.revoke(id: c.id) } catch { first = error }
        #expect(try #require(first as? RevokeIncomplete).isDurablyFenced == false)

        // The keychain recovers enough for the INTENT write but not the authorization write: the same
        // `revoke` call the UI's Retry makes must promote the row to a durable fence.
        intents.failWrite = false
        var second: (any Error)?
        do { try await pairing.revoke(id: c.id) } catch { second = error }
        #expect(try #require(second as? RevokeIncomplete).isDurablyFenced == true)
        auth.failWrite = false

        #expect(try durableIntents(intents) == [c.id])
        let restarted = PairingStore(store: auth, revokeIntentStore: intents,
                                     now: { Date(timeIntervalSince1970: 3000) })
        #expect(await restarted.isAuthorized(id: c.id) == false)
        #expect(await restarted.pendingRevocations() == .known(durable: [c.id], enrollmentFenced: []))
    }

    /// The enroll-false-success finding. `authorizedMap()` subtracts pending intents, so a clear that
    /// cannot be made durable leaves the key that was JUST enrolled unauthorizable — and the
    /// best-effort clear let `runEnrollmentCeremony` emit `.enrollmentResolved(approved: true)` for it.
    /// Enrollment must fail closed instead: the UI never claims an authorization outcome the gate
    /// contradicts.
    @Test func enrollThrowsRatherThanReportingSuccessForAKeyThatStaysFenced() async throws {
        let auth = MemoryStore()
        let intents = MemoryStore()
        let pairing = PairingStore(store: auth, revokeIntentStore: intents,
                                   now: { Date(timeIntervalSince1970: 2000) })
        let c = newClient()
        try await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")
        auth.failWrite = true
        await #expect(throws: (any Error).self) { try await pairing.revoke(id: c.id) }
        auth.failWrite = false
        #expect(await pairing.isAuthorized(id: c.id) == false)  // fenced by the durable intent

        intents.failWrite = true  // the attended re-pair cannot lift the fence
        await #expect(throws: (any Error).self) {
            try await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone re-paired")
        }
        intents.failWrite = false
        // The refusal was honest: the key really is still denied, in this process and the next.
        #expect(await pairing.isAuthorized(id: c.id) == false)
        #expect(try durableIntents(intents) == [c.id])
        let restarted = PairingStore(store: auth, revokeIntentStore: intents,
                                     now: { Date(timeIntervalSince1970: 3000) })
        #expect(await restarted.isAuthorized(id: c.id) == false)
        #expect(await restarted.pendingRevocations() == .known(durable: [c.id], enrollmentFenced: []))
    }

    /// Same false success via the UNREADABLE intent item rather than a failed write: a cold
    /// thrown/undecodable intent read makes `authorizedMap()` deny EVERYONE (correct, fail closed), so
    /// an enrollment completed over it would be reported as approved and then refused at the gate.
    @Test func enrollThrowsWhenAPendingIntentCannotEvenBeRead() async throws {
        let auth = MemoryStore()
        let intents = MemoryStore(Data([0xDE, 0xAD]))  // undecodable intent blob
        let pairing = PairingStore(store: auth, revokeIntentStore: intents,
                                   now: { Date(timeIntervalSince1970: 2000) })
        let c = newClient()
        await #expect(throws: (any Error).self) {
            try await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")
        }
        #expect(await pairing.isAuthorized(id: c.id) == false)
        // The authorization record WAS written (the clear is deliberately ordered after `persist`), so
        // the device keeps a visible row the owner can act on rather than vanishing — and the surface
        // is told the store is unreadable rather than shown a clean, empty pending list.
        #expect(await pairing.list().map(\.id) == [c.id])
        #expect(await pairing.pendingRevocations() == .unreadable)
    }

    /// `pendingRevocations()` must not launder an unreadable intent item into a reassuring empty set:
    /// authorization fails closed on that same read, so "nothing pending" would be shown at the exact
    /// moment nothing is authorized.
    @Test func pendingRevocationsReportsUnreadableRatherThanACleanEmptySet() async throws {
        let auth = MemoryStore()
        let intents = MemoryStore()
        let pairing = PairingStore(store: auth, revokeIntentStore: intents,
                                   now: { Date(timeIntervalSince1970: 2000) })
        let c = newClient()
        try await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")

        let restarted = PairingStore(store: auth, revokeIntentStore: intents,
                                     now: { Date(timeIntervalSince1970: 3000) })
        intents.failRead = true  // cold intent cache + throwing read
        #expect(await restarted.isAuthorized(id: c.id) == false)
        #expect(await restarted.pendingRevocations() == .unreadable)
    }

    @Test func unreadableIntentItemFailsClosedOnAColdRead() async throws {
        // Fail CLOSED everywhere: if we cannot verify that no revocation is pending for a key, we do
        // not authorize it. (Symmetric with a cold authorization-item read failure, which already
        // denies everyone.)
        let auth = MemoryStore()
        let intents = MemoryStore()
        let pairing = PairingStore(store: auth, revokeIntentStore: intents,
                                   now: { Date(timeIntervalSince1970: 2000) })
        let c = newClient()
        try await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")

        let restarted = PairingStore(store: auth, revokeIntentStore: intents,
                                     now: { Date(timeIntervalSince1970: 3000) })
        intents.failRead = true  // cold intent cache + throwing read
        #expect(await restarted.isAuthorized(id: c.id) == false)
        #expect(await restarted.authorizedClient(forPublicKey: c.publicKey) == nil)
    }

    @Test func corruptIntentBlobFailsClosed() async throws {
        let auth = MemoryStore()
        let seed = PairingStore(store: auth, now: { Date(timeIntervalSince1970: 2000) })
        let c = newClient()
        try await seed.enroll(publicKey: c.publicKey, deviceName: "iPhone")
        let pairing = PairingStore(store: auth, revokeIntentStore: MemoryStore(Data([0xDE, 0xAD])),
                                   now: { Date(timeIntervalSince1970: 3000) })
        #expect(await pairing.isAuthorized(id: c.id) == false)
    }

    @Test func warmIntentCacheKeepsAuthorizingWhenTheIntentItemLocksMidSession() async throws {
        // Mirrors `cachedMapSurvivesAKeychainThatLocksMidSession` for the new item: once the intent
        // set has been read successfully, a keychain that locks mid-session must not brick a live
        // host by denying an already-known device.
        let auth = MemoryStore()
        let intents = MemoryStore()
        let pairing = PairingStore(store: auth, revokeIntentStore: intents,
                                   now: { Date(timeIntervalSince1970: 2000) })
        let c = newClient()
        try await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")
        #expect(await pairing.isAuthorized(id: c.id) == true)  // warms both caches
        intents.failRead = true
        #expect(await pairing.isAuthorized(id: c.id) == true)
    }

    /// The UI-visibility half of §6d: a fresh process must be able to SEE which enrolled rows are
    /// mid-revoke so it can render Retry / LAContext-gated Cancel without an in-process `RevokeLease`.
    @Test func pendingRevocationsIsVisibleToAFreshInstanceAndClearsOnCompletion() async throws {
        let auth = MemoryStore()
        let intents = MemoryStore()
        let pairing = PairingStore(store: auth, revokeIntentStore: intents,
                                   now: { Date(timeIntervalSince1970: 2000) })
        let c = newClient()
        let other = newClient()
        try await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")
        try await pairing.enroll(publicKey: other.publicKey, deviceName: "iPad")
        #expect(await pairing.pendingRevocations() == .known(durable: [], enrollmentFenced: []))

        auth.failWrite = true
        await #expect(throws: (any Error).self) { try await pairing.revoke(id: c.id) }
        auth.failWrite = false

        let restarted = PairingStore(store: auth, revokeIntentStore: intents,
                                     now: { Date(timeIntervalSince1970: 3000) })
        #expect(await restarted.pendingRevocations() == .known(durable: [c.id], enrollmentFenced: []))  // only the wedged one
        #expect(await restarted.isAuthorized(id: other.id) == true)      // its sibling is unaffected
        try await restarted.revoke(id: c.id)                              // Retry, no lease needed
        // Clear-on-completion is asserted against the DURABLE item. `pendingRevocations()` alone
        // cannot prove it: it intersects with the enrolled set, and the completed removal already
        // took K out of that set — so a lingering intent for K would be filtered away and the old
        // `.isEmpty` assertion passed whether or not the clear ever ran.
        #expect(try durableIntents(intents).isEmpty)
        #expect(await restarted.pendingRevocations() == .known(durable: [], enrollmentFenced: []))
    }

    @Test func cancelRevocationIntentReAdmitsTheStillEnrolledDevice() async throws {
        // §1a step 5 Cancel: the authenticated escape hatch for a permanently-wedged keychain —
        // deliberately re-admitting a device whose durable record was never removed.
        let auth = MemoryStore()
        let intents = MemoryStore()
        let pairing = PairingStore(store: auth, revokeIntentStore: intents,
                                   now: { Date(timeIntervalSince1970: 2000) })
        let c = newClient()
        try await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")
        auth.failWrite = true
        await #expect(throws: (any Error).self) { try await pairing.revoke(id: c.id) }
        auth.failWrite = false

        let restarted = PairingStore(store: auth, revokeIntentStore: intents,
                                     now: { Date(timeIntervalSince1970: 3000) })
        #expect(await restarted.isAuthorized(id: c.id) == false)
        try await restarted.cancelRevocationIntent(id: c.id)
        #expect(await restarted.isAuthorized(id: c.id) == true)
        #expect(await restarted.pendingRevocations() == .known(durable: [], enrollmentFenced: []))
        // The re-admission was DURABLE, not just this instance's cache.
        let afterAnotherRestart = PairingStore(store: auth, revokeIntentStore: intents,
                                               now: { Date(timeIntervalSince1970: 4000) })
        #expect(await afterAnotherRestart.isAuthorized(id: c.id) == true)
    }

    @Test func cancelRevocationIntentThrowsRatherThanReportingAFalseReAdmission() async throws {
        let auth = MemoryStore()
        let intents = MemoryStore()
        let pairing = PairingStore(store: auth, revokeIntentStore: intents,
                                   now: { Date(timeIntervalSince1970: 2000) })
        let c = newClient()
        try await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")
        auth.failWrite = true
        await #expect(throws: (any Error).self) { try await pairing.revoke(id: c.id) }
        auth.failWrite = false

        intents.failWrite = true  // the fence cannot be lifted durably
        await #expect(throws: (any Error).self) { try await pairing.cancelRevocationIntent(id: c.id) }
        intents.failWrite = false
        // Still fenced — the caller must not have told the user the device was re-admitted.
        let restarted = PairingStore(store: auth, revokeIntentStore: intents,
                                     now: { Date(timeIntervalSince1970: 3000) })
        #expect(await restarted.isAuthorized(id: c.id) == false)
        #expect(await restarted.pendingRevocations() == .known(durable: [c.id], enrollmentFenced: []))
    }

    @Test func aPendingIntentForOneKeyNeverFencesAnother() async throws {
        let auth = MemoryStore()
        let intents = MemoryStore()
        let pairing = PairingStore(store: auth, revokeIntentStore: intents,
                                   now: { Date(timeIntervalSince1970: 2000) })
        let a = newClient()
        let b = newClient()
        try await pairing.enroll(publicKey: a.publicKey, deviceName: "A")
        try await pairing.enroll(publicKey: b.publicKey, deviceName: "B")

        // A SECOND actor over the same items (the app/CLI shape), warmed BEFORE any intent is written.
        // This is what makes the second half a real counterexample: with one actor, the intent cache
        // already holds A by the time B's revoke runs, so a `mutableIntents()` that wrongly served the
        // warm cache still produced {A, B} and the test passed for the wrong reason.
        let secondProcess = PairingStore(store: auth, revokeIntentStore: intents,
                                         now: { Date(timeIntervalSince1970: 2500) })
        #expect(await secondProcess.isAuthorized(id: a.id) == true)  // warms its intent cache with {}
        #expect(await secondProcess.isAuthorized(id: b.id) == true)

        auth.failWrite = true
        await #expect(throws: (any Error).self) { try await pairing.revoke(id: a.id) }
        auth.failWrite = false
        #expect(try durableIntents(intents) == [a.id])
        #expect(await pairing.isAuthorized(id: a.id) == false)
        #expect(await pairing.isAuthorized(id: b.id) == true)
        #expect(await pairing.authorizedClient(forPublicKey: b.publicKey)?.id == b.id)

        // The second, stale-warm actor now wedges its own revoke of B. Its intent read-modify-write
        // must re-read the durable set ({A}) rather than write a lone-entry {B} from its warm {} —
        // dropping A's fence would silently re-admit A.
        auth.failWrite = true
        await #expect(throws: (any Error).self) { try await secondProcess.revoke(id: b.id) }
        auth.failWrite = false
        #expect(try durableIntents(intents) == Set([a.id, b.id]))
        let restarted = PairingStore(store: auth, revokeIntentStore: intents,
                                     now: { Date(timeIntervalSince1970: 3000) })
        #expect(await restarted.pendingRevocations() == .known(durable: Set([a.id, b.id]), enrollmentFenced: []))
        #expect(await restarted.isAuthorized(id: a.id) == false)
    }

    @Test func revokingANeverEnrolledIdLeavesNoLingeringIntent() async throws {
        let auth = MemoryStore()
        let intents = MemoryStore()
        let pairing = PairingStore(store: auth, revokeIntentStore: intents,
                                   now: { Date(timeIntervalSince1970: 2000) })
        let c = newClient()
        try await pairing.revoke(id: c.id)  // no-op: never enrolled
        // The no-op recorded an intent on entry and must have discharged it. Asserted against the
        // DURABLE item: the old version enrolled the key next and checked `isAuthorized`, but `enroll`
        // clears the intent itself, so it passed even with a lingering fence. `pendingRevocations()`
        // can't prove it either — it intersects with the enrolled set, and the key is not enrolled.
        #expect(try durableIntents(intents).isEmpty)
        let restarted = PairingStore(store: auth, revokeIntentStore: intents,
                                     now: { Date(timeIntervalSince1970: 3000) })
        #expect(await restarted.pendingRevocations() == .known(durable: [], enrollmentFenced: []))
    }

    // MARK: - lastSeen split (§6c, han.4 H-a): touch can never resurrect a revoked key

    @Test func touchDoesNotResurrectARevokedKey() async throws {
        let store = MemoryStore()
        let pairing = PairingStore(store: store, now: { Date(timeIntervalSince1970: 2000) })
        let c = newClient()
        try await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")
        try await pairing.revoke(id: c.id)
        try await pairing.touch(id: c.id)  // must be a no-op re: authorization
        #expect(await pairing.isAuthorized(id: c.id) == false)
        #expect(await pairing.list().isEmpty)
        #expect(await pairing.authorizedClient(forPublicKey: c.publicKey) == nil)
    }

    @Test func touchNeverWritesToTheAuthorizationItem() async throws {
        // Direct evidence for "by construction, not by read ordering": touch produces ZERO writes
        // to the auth store, whether or not the id is enrolled.
        let authStore = MemoryStore()
        let pairing = PairingStore(store: authStore, now: { Date(timeIntervalSince1970: 2000) })
        let c = newClient()
        try await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")
        let writesAfterEnroll = authStore.writeCount
        try await pairing.touch(id: c.id)
        #expect(authStore.writeCount == writesAfterEnroll)
    }

    /// CROSS-PROCESS BARRIER (§6c, H-a): two `PairingStore` instances over INDEPENDENT auth stores
    /// but a SHARED lastSeen fake — the shape of the app/CLI pairing (one physical keychain,
    /// per-process actor caches). Pauses instance-B's `touch(K)` AFTER its lastSeen read (so it
    /// holds a stale snapshot), lets instance-A `revoke(K)` run to completion (removing K from A's
    /// auth item AND best-effort deleting `lastSeen[K]` from the shared item), then resumes B's
    /// touch. Before the fix, a whole-blob read-modify-write of a SHARED item would have let B's
    /// stale write clobber A's revoke; after the fix, `touch` never touches an auth item at all, so
    /// K stays absent from A's auth item regardless of the interleaving. The shared lastSeen item
    /// MAY still end up with a stale `lastSeen[K]` (B's write wins the lastSeen race) — that is the
    /// documented, accepted residual (H-a): lastSeen never gates authorization, and `list()` never
    /// surfaces an entry for a key absent from the auth item, so the residual is inert.
    @Test func crossProcessBarrierTouchNeverRewritesTheAuthorizationItem() async throws {
        let sharedLastSeen = MemoryLastSeenStore()
        let storeA = MemoryStore()
        let storeB = MemoryStore()
        let instanceA = PairingStore(store: storeA, lastSeenStore: sharedLastSeen,
                                     now: { Date(timeIntervalSince1970: 1000) })
        let instanceB = PairingStore(store: storeB, lastSeenStore: sharedLastSeen,
                                     now: { Date(timeIntervalSince1970: 1000) })
        let c = newClient()
        // Both processes' views start with K enrolled (their independent auth stores plus the one
        // shared lastSeen item, mirroring the real single-keychain-item, per-process-cache shape).
        try await instanceA.enroll(publicKey: c.publicKey, deviceName: "app-view")
        try await instanceB.enroll(publicKey: c.publicKey, deviceName: "cli-view")
        let writesToBBeforeTouch = storeB.writeCount

        sharedLastSeen.armPauseOnNextRead()
        let touchTask = Task { try? await instanceB.touch(id: c.id) }
        sharedLastSeen.waitUntilReadPaused()  // B has read (paused) the shared lastSeen blob

        try await instanceA.revoke(id: c.id)  // removes K from A's auth item; best-effort deletes lastSeen[K]
        #expect(await instanceA.isAuthorized(id: c.id) == false)
        #expect(await instanceA.list().isEmpty)

        sharedLastSeen.continueRead()  // let B's paused read return its STALE (pre-revoke) snapshot
        await touchTask.value

        // The invariant that matters: A's auth item is UNCHANGED by B's touch completing after the
        // revoke — no resurrection, regardless of the read/write interleaving.
        #expect(await instanceA.isAuthorized(id: c.id) == false)
        #expect(await instanceA.list().isEmpty)
        #expect(await instanceA.authorizedClient(forPublicKey: c.publicKey) == nil)
        // touch on B never wrote to EITHER auth store — only the shared lastSeen item.
        #expect(storeA.writeCount == 2)  // A's own enroll + revoke; nothing from B's touch
        #expect(storeB.writeCount == writesToBBeforeTouch)  // B's touch wrote nothing to B's auth item

        // Documented residual: the shared lastSeen item may still show K (B's stale write landed
        // after A's delete) — harmless because it is never surfaced (see next test) and never
        // consulted for authorization.
        let rawLastSeen = try #require(sharedLastSeen.rawBlob())
        let decoded = try JSONDecoder().decode([String: Date].self, from: rawLastSeen)
        #expect(decoded[c.id] != nil, "documented H-a residual: a stale touch may still resurrect lastSeen (never the auth item)")
    }

    @Test func listJoinsLastSeenDefaultingToEnrolledAtWhenAbsent() async throws {
        let lastSeenStore = MemoryLastSeenStore()
        let pairing = PairingStore(store: MemoryStore(), lastSeenStore: lastSeenStore,
                                   now: { Date(timeIntervalSince1970: 1000) })
        let c = newClient()
        try await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")  // seeds lastSeen too

        // Simulate a lastSeen item with no entry for this id (e.g. an auth item that predates the
        // lastSeen split): wipe the lastSeen store directly.
        try lastSeenStore.write(JSONEncoder().encode([String: Date]()))
        let beforeTouch = await pairing.list()
        #expect(beforeTouch.first?.lastSeen == beforeTouch.first?.enrolledAt)

        try await pairing.touch(id: c.id)
        let afterTouch = await pairing.list()
        #expect(afterTouch.first?.lastSeen == Date(timeIntervalSince1970: 1000))
    }

    @Test func listDoesNotSurfaceOrphanLastSeenForARevokedKey() async throws {
        let lastSeenStore = MemoryLastSeenStore()
        let pairing = PairingStore(store: MemoryStore(), lastSeenStore: lastSeenStore,
                                   now: { Date(timeIntervalSince1970: 2000) })
        let c = newClient()
        try await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")
        try await pairing.touch(id: c.id)
        // Force revoke's best-effort lastSeen delete to fail, so an orphan genuinely remains in the
        // lastSeen item after K is removed from the authorization item.
        lastSeenStore.failWrite = true
        try await pairing.revoke(id: c.id)
        lastSeenStore.failWrite = false

        // The orphan is still physically present in the lastSeen item...
        let raw = try #require(lastSeenStore.rawBlob())
        let seen = try JSONDecoder().decode([String: Date].self, from: raw)
        #expect(seen[c.id] != nil)
        // ...but list() never surfaces it: K is absent from the authorization item.
        #expect(await pairing.list().isEmpty)
        #expect(await pairing.isAuthorized(id: c.id) == false)
    }

    @Test func enrollSeedsTheLastSeenItem() async throws {
        let lastSeenStore = MemoryLastSeenStore()
        let pairing = PairingStore(store: MemoryStore(), lastSeenStore: lastSeenStore,
                                   now: { Date(timeIntervalSince1970: 4000) })
        let c = newClient()
        try await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")
        let raw = try #require(lastSeenStore.rawBlob())
        let seen = try JSONDecoder().decode([String: Date].self, from: raw)
        #expect(seen[c.id] == Date(timeIntervalSince1970: 4000))
    }

    @Test func revokeBestEffortDeletesTheLastSeenItem() async throws {
        let lastSeenStore = MemoryLastSeenStore()
        let pairing = PairingStore(store: MemoryStore(), lastSeenStore: lastSeenStore,
                                   now: { Date(timeIntervalSince1970: 4000) })
        let c = newClient()
        try await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")
        try await pairing.revoke(id: c.id)
        let raw = try #require(lastSeenStore.rawBlob())
        let seen = try JSONDecoder().decode([String: Date].self, from: raw)
        #expect(seen[c.id] == nil)
    }

    @Test func thrownLastSeenReadNoOpsAndDoesNotBreakAuthOperations() async throws {
        let lastSeenStore = MemoryLastSeenStore()
        let pairing = PairingStore(store: MemoryStore(), lastSeenStore: lastSeenStore,
                                   now: { Date(timeIntervalSince1970: 6000) })
        let c = newClient()
        lastSeenStore.failRead = true

        // enroll: the auth write must still succeed even though seeding lastSeen throws.
        try await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")
        #expect(await pairing.isAuthorized(id: c.id) == true)

        // list(): still returns the authorized client; lastSeen falls back to enrolledAt.
        let entries = await pairing.list()
        #expect(entries.first?.id == c.id)
        #expect(entries.first?.lastSeen == entries.first?.enrolledAt)

        // touch(): silently no-ops, never throws upward.
        try await pairing.touch(id: c.id)

        // revoke(): the auth removal still succeeds even though the lastSeen delete throws.
        try await pairing.revoke(id: c.id)
        #expect(await pairing.isAuthorized(id: c.id) == false)
    }

    @Test func thrownLastSeenWriteNoOpsAndDoesNotBreakTouchOrEnroll() async throws {
        let lastSeenStore = MemoryLastSeenStore()
        lastSeenStore.failWrite = true
        let pairing = PairingStore(store: MemoryStore(), lastSeenStore: lastSeenStore,
                                   now: { Date(timeIntervalSince1970: 7000) })
        let c = newClient()

        // enroll: the auth write succeeds; the lastSeen seed write silently fails.
        try await pairing.enroll(publicKey: c.publicKey, deviceName: "iPhone")
        #expect(await pairing.isAuthorized(id: c.id) == true)

        // touch(): read succeeds (empty item), write throws — silently no-ops.
        try await pairing.touch(id: c.id)

        let entries = await pairing.list()
        #expect(entries.first?.lastSeen == entries.first?.enrolledAt)  // the write never landed
    }
    private final class PausableStore: PairingRecordStore, @unchecked Sendable {
        private let lock = NSLock()
        private var blob: Data?
        private var pauseNextRead = false
        var failRead = false
        private let paused = DispatchSemaphore(value: 0)
        private let resumed = DispatchSemaphore(value: 0)
        private let additionalRead = DispatchSemaphore(value: 0)

        init(_ blob: Data? = nil) { self.blob = blob }

        func armPauseOnNextRead() {
            lock.lock(); pauseNextRead = true; lock.unlock()
        }

        func waitUntilPaused() -> Bool {
            paused.wait(timeout: .now() + 5) == .success
        }

        func waitForAdditionalRead() -> Bool {
            additionalRead.wait(timeout: .now() + 5) == .success
        }

        func resume() { resumed.signal() }

        func read() throws -> Data? {
            lock.lock()
            if failRead { lock.unlock(); throw TestStoreError.injected }
            let snapshot = blob
            let shouldPause = pauseNextRead
            if shouldPause { pauseNextRead = false }
            lock.unlock()
            if shouldPause {
                paused.signal()
                resumed.wait()
            } else {
                additionalRead.signal()
            }
            return snapshot
        }

        func write(_ data: Data) throws {
            lock.lock(); blob = data; lock.unlock()
        }

        func rawBlob() -> Data? {
            lock.lock(); defer { lock.unlock() }
            return blob
        }
    }

    private final class SharedMemoryMutationLock: PairingMutationLock, @unchecked Sendable {
        private let condition = NSCondition()
        private var held = false
        private var nextToken: Int32 = 1
        private var attempts = 0
        private let secondAttempt = DispatchSemaphore(value: 0)

        func acquire() throws -> Int32 {
            condition.lock()
            attempts += 1
            if attempts == 2 { secondAttempt.signal() }
            while held { condition.wait() }
            held = true
            let token = nextToken
            nextToken += 1
            condition.unlock()
            return token
        }

        func release(_ token: Int32) {
            condition.lock()
            held = false
            condition.broadcast()
            condition.unlock()
        }

        func waitForSecondAttempt() -> Bool {
            secondAttempt.wait(timeout: .now() + 5) == .success
        }
    }

    @Test(arguments: [false, true])
    func concurrentRevokesPreserveBothRemovals(withLock: Bool) async throws {
        let auth = PausableStore()
        let intents = PausableStore()
        let firstClient = newClient()
        let secondClient = newClient()
        let setup = PairingStore(store: auth, revokeIntentStore: intents)
        try await setup.enroll(publicKey: firstClient.publicKey, deviceName: "K")
        try await setup.enroll(publicKey: secondClient.publicKey, deviceName: "J")
        let sharedLock = SharedMemoryMutationLock()
        let lock: any PairingMutationLock = withLock ? sharedLock : NoopPairingMutationLock()
        let first = PairingStore(store: auth, lastSeenStore: MemoryLastSeenStore(),
                                 revokeIntentStore: intents, mutationLock: lock)
        let second = PairingStore(store: auth, lastSeenStore: MemoryLastSeenStore(),
                                  revokeIntentStore: intents, mutationLock: lock)

        auth.armPauseOnNextRead()
        let firstTask = Task { try await first.revoke(id: firstClient.id) }
        guard auth.waitUntilPaused() else {
            auth.resume()
            Issue.record("first authorization read did not pause")
            return
        }
        let secondTask = Task { try await second.revoke(id: secondClient.id) }
        let overlapObserved = withLock ? sharedLock.waitForSecondAttempt() : auth.waitForAdditionalRead()
        #expect(overlapObserved)
        auth.resume()
        try await firstTask.value
        try await secondTask.value

        let final = PairingStore(store: auth)
        let ids = Set(await final.list().map { $0.id })
        #expect(withLock ? ids.isEmpty : !ids.isEmpty)
    }

    @Test(arguments: [false, true])
    func concurrentEnrollAndRevokePreserveUnionOfEffects(withLock: Bool) async throws {
        let auth = PausableStore()
        let intents = PausableStore()
        let revoked = newClient()
        let retained = newClient()
        let added = newClient()
        let setup = PairingStore(store: auth, revokeIntentStore: intents)
        try await setup.enroll(publicKey: revoked.publicKey, deviceName: "K")
        try await setup.enroll(publicKey: retained.publicKey, deviceName: "J")
        let sharedLock = SharedMemoryMutationLock()
        let lock: any PairingMutationLock = withLock ? sharedLock : NoopPairingMutationLock()
        let first = PairingStore(store: auth, lastSeenStore: MemoryLastSeenStore(),
                                 revokeIntentStore: intents, mutationLock: lock)
        let second = PairingStore(store: auth, lastSeenStore: MemoryLastSeenStore(),
                                  revokeIntentStore: intents, mutationLock: lock)

        auth.armPauseOnNextRead()
        let enrollTask = Task { try await first.enroll(publicKey: added.publicKey, deviceName: "X") }
        guard auth.waitUntilPaused() else {
            auth.resume()
            Issue.record("enrollment authorization read did not pause")
            return
        }
        let revokeTask = Task { try await second.revoke(id: revoked.id) }
        let overlapObserved = withLock ? sharedLock.waitForSecondAttempt() : auth.waitForAdditionalRead()
        #expect(overlapObserved)
        auth.resume()
        try await enrollTask.value
        try await revokeTask.value

        let final = PairingStore(store: auth)
        let ids = Set(await final.list().map { $0.id })
        let expected: Set<String> = [retained.id, added.id]
        #expect(withLock ? ids == expected : ids.contains(revoked.id))
    }

    @Test(arguments: [false, true])
    func concurrentFailedRevokesPreserveBothIntents(withLock: Bool) async {
        let auth = PausableStore()
        auth.failRead = true
        let intents = PausableStore()
        let sharedLock = SharedMemoryMutationLock()
        let lock: any PairingMutationLock = withLock ? sharedLock : NoopPairingMutationLock()
        let first = PairingStore(store: auth, lastSeenStore: MemoryLastSeenStore(),
                                 revokeIntentStore: intents, mutationLock: lock)
        let second = PairingStore(store: auth, lastSeenStore: MemoryLastSeenStore(),
                                  revokeIntentStore: intents, mutationLock: lock)

        intents.armPauseOnNextRead()
        let firstTask = Task { try? await first.revoke(id: "K") }
        guard intents.waitUntilPaused() else {
            intents.resume()
            Issue.record("first intent read did not pause")
            return
        }
        let secondTask = Task { try? await second.revoke(id: "J") }
        let overlapObserved = withLock ? sharedLock.waitForSecondAttempt() : intents.waitForAdditionalRead()
        #expect(overlapObserved)
        intents.resume()
        _ = await firstTask.value
        _ = await secondTask.value

        let final = intents.rawBlob()
            .flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? []
        #expect(withLock ? final == ["K", "J"] : final.count == 1)
    }

    private final class RecordingMutationLock: PairingMutationLock, @unchecked Sendable {
        private let lock = NSLock()
        private var held = false
        private(set) var acquisitions = 0
        private(set) var releases = 0

        func acquire() throws -> Int32 {
            lock.lock()
            acquisitions += 1
            held = true
            lock.unlock()
            return Int32(acquisitions)
        }

        func release(_ token: Int32) {
            lock.lock()
            held = false
            releases += 1
            lock.unlock()
        }

        func isHeld() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return held
        }
    }

    private final class LockCheckingStore: PairingRecordStore, @unchecked Sendable {
        private let lock = NSLock()
        private let mutationLock: RecordingMutationLock
        private var blob: Data?
        var failRead = false
        private(set) var accessOutsideLock = false

        init(mutationLock: RecordingMutationLock) {
            self.mutationLock = mutationLock
        }

        func read() throws -> Data? {
            lock.lock(); defer { lock.unlock() }
            if !mutationLock.isHeld() { accessOutsideLock = true }
            if failRead { throw TestStoreError.injected }
            return blob
        }

        func write(_ data: Data) throws {
            lock.lock(); defer { lock.unlock() }
            if !mutationLock.isHeld() { accessOutsideLock = true }
            blob = data
        }
    }

    @Test func enrollAcquiresOnceAndKeepsAuthorizationAndIntentAccessesInsideLock() async throws {
        let recordingLock = RecordingMutationLock()
        let auth = LockCheckingStore(mutationLock: recordingLock)
        let intents = LockCheckingStore(mutationLock: recordingLock)
        let pairing = PairingStore(store: auth, lastSeenStore: MemoryLastSeenStore(),
                                   revokeIntentStore: intents, mutationLock: recordingLock)
        let client = newClient()

        try await pairing.enroll(publicKey: client.publicKey, deviceName: "X")

        #expect(recordingLock.acquisitions == 1)
        #expect(recordingLock.releases == 1)
        #expect(!auth.accessOutsideLock)
        #expect(!intents.accessOutsideLock)
    }

    @Test func revokeAcquiresOnceAndReleasesOnEarlySuccess() async throws {
        let recordingLock = RecordingMutationLock()
        let auth = LockCheckingStore(mutationLock: recordingLock)
        let intents = LockCheckingStore(mutationLock: recordingLock)
        let pairing = PairingStore(store: auth, lastSeenStore: MemoryLastSeenStore(),
                                   revokeIntentStore: intents, mutationLock: recordingLock)

        try await pairing.revoke(id: "absent")

        #expect(recordingLock.acquisitions == 1)
        #expect(recordingLock.releases == 1)
        #expect(!auth.accessOutsideLock)
        #expect(!intents.accessOutsideLock)
    }

    @Test func cancelAcquiresOnceAndReleasesWhenStoreThrows() async {
        let recordingLock = RecordingMutationLock()
        let auth = LockCheckingStore(mutationLock: recordingLock)
        let intents = LockCheckingStore(mutationLock: recordingLock)
        intents.failRead = true
        let pairing = PairingStore(store: auth, lastSeenStore: MemoryLastSeenStore(),
                                   revokeIntentStore: intents, mutationLock: recordingLock)

        await #expect(throws: TestStoreError.self) {
            try await pairing.cancelRevocationIntent(id: "K")
        }
        #expect(recordingLock.acquisitions == 1)
        #expect(recordingLock.releases == 1)
        #expect(!auth.accessOutsideLock)
        #expect(!intents.accessOutsideLock)
    }

    private struct FailingMutationLock: PairingMutationLock {
        func acquire() throws -> Int32 { throw TestStoreError.injected }
        func release(_ token: Int32) {}
    }

    @Test func lockFailureAbortsEnrollBeforeStoreAccess() async {
        let store = MemoryStore()
        let pairing = PairingStore(
            store: store,
            lastSeenStore: MemoryLastSeenStore(),
            revokeIntentStore: MemoryStore(),
            mutationLock: FailingMutationLock())
        let client = newClient()

        await #expect(throws: PairingStoreError.self) {
            try await pairing.enroll(publicKey: client.publicKey, deviceName: "iPhone")
        }
        #expect(store.writeCount == 0)
    }

    @Test func revokeMapsLockFailureToUnknownDurability() async {
        let pairing = PairingStore(
            store: MemoryStore(),
            lastSeenStore: MemoryLastSeenStore(),
            revokeIntentStore: MemoryStore(),
            mutationLock: FailingMutationLock())

        do {
            try await pairing.revoke(id: "K")
            Issue.record("expected revoke to fail")
        } catch let error as RevokeIncomplete {
            #expect(error.isDurablyFenced == false)
            #expect(error.isProvenNotDurable == false)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func fileMutationLockTimesOutThenAcquiresAfterRelease() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("pairings.mutation.lock")
        let first = FilePairingMutationLock(url: url, timeout: 0.05)
        let second = FilePairingMutationLock(url: url, timeout: 0.05)

        let firstToken = try first.acquire()
        #expect(throws: PairingStoreError.self) {
            _ = try second.acquire()
        }
        first.release(firstToken)
        let secondToken = try second.acquire()
        second.release(secondToken)
    }

    @Test func fileMutationLockPathErrorFailsClosed() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data().write(to: parent)
        defer { try? FileManager.default.removeItem(at: parent) }
        let lock = FilePairingMutationLock(
            url: parent.appendingPathComponent("pairings.mutation.lock"),
            timeout: 0.05)

        #expect(throws: PairingStoreError.self) {
            _ = try lock.acquire()
        }
    }

}

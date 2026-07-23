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
}

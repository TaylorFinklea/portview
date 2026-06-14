import Testing
import Foundation
@testable import PortviewTransport

/// In-memory `IdentityRecordStore` so persistence logic is tested without touching the real
/// login keychain (deterministic, side-effect-free).
final class InMemoryIdentityStore: IdentityRecordStore, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    func read(service: String) throws -> Data? { storage[service] }
    func write(_ data: Data, service: String) throws { storage[service] = data }
}

/// Always-failing store, modeling the unsigned-CLI / denied-keychain case.
struct FailingIdentityStore: IdentityRecordStore {
    struct Failure: Error {}
    func read(service: String) throws -> Data? { throw Failure() }
    func write(_ data: Data, service: String) throws { throw Failure() }
}

/// Reads succeed but writes always fail — models a keychain that can be read but not written
/// (so nothing is ever persisted).
final class WriteFailingIdentityStore: IdentityRecordStore, @unchecked Sendable {
    struct Failure: Error {}
    private let backing = InMemoryIdentityStore()
    func read(service: String) throws -> Data? { try backing.read(service: service) }
    func write(_ data: Data, service: String) throws { throw Failure() }
}

@Suite struct IdentityPersistenceTests {
    /// The pin survives a "restart": load-or-create twice against the same store yields the same
    /// certificate fingerprint (the stored identity is re-imported, not regenerated).
    @Test func loadOrCreateYieldsStablePinAcrossLoads() throws {
        let store = InMemoryIdentityStore()
        let first = try TLSIdentity.loadOrCreatePersistent(
            service: "test.identity", commonName: "Test", store: store, now: Date())
        let second = try TLSIdentity.loadOrCreatePersistent(
            service: "test.identity", commonName: "Test", store: store, now: Date())

        #expect(try first.identity.certificateSHA256() == second.identity.certificateSHA256())
        #expect(first.port == nil)   // freshly minted, port not yet bound
        #expect(second.port == nil)  // stored sentinel 0 → nil
        #expect(first.persistent)    // minted + stored successfully
        #expect(second.persistent)   // loaded from the store
    }

    /// When the record can't be written, the identity is still usable but flagged non-persistent,
    /// and a subsequent load mints a DIFFERENT identity (pin churns — the documented best-effort).
    @Test func mintNotPersistedWhenWriteFails() throws {
        let store = WriteFailingIdentityStore()
        let first = try TLSIdentity.loadOrCreatePersistent(
            service: "test.identity", commonName: "Test", store: store, now: Date())
        let second = try TLSIdentity.loadOrCreatePersistent(
            service: "test.identity", commonName: "Test", store: store, now: Date())

        #expect(!first.persistent)
        #expect(try first.identity.certificateSHA256() != second.identity.certificateSHA256())
    }

    /// `persistPort(0, …)` is a no-op (0 is the not-bound sentinel) and must not corrupt the record.
    @Test func persistPortIgnoresZeroPort() throws {
        let store = InMemoryIdentityStore()
        let original = try TLSIdentity.loadOrCreatePersistent(
            service: "test.identity", commonName: "Test", store: store, now: Date())

        TLSIdentity.persistPort(0, service: "test.identity", store: store)

        let loaded = try TLSIdentity.loadOrCreatePersistent(
            service: "test.identity", commonName: "Test", store: store, now: Date())
        #expect(loaded.port == nil)  // still unbound, not corrupted
        #expect(try loaded.identity.certificateSHA256() == original.identity.certificateSHA256())
    }

    /// A corrupted PKCS#12 blob triggers a re-mint (different pin), and the fresh record overwrites
    /// the corrupt one so the next load is stable (self-heals — no churn loop).
    @Test func corruptedBlobRemintsAndSelfHeals() throws {
        let store = InMemoryIdentityStore()
        let original = try TLSIdentity.loadOrCreatePersistent(
            service: "test.identity", commonName: "Test", store: store, now: Date())
        let originalPin = try original.identity.certificateSHA256()

        // Overwrite the stored record's blob with garbage (valid JSON, unimportable p12).
        let corrupt = StoredIdentityRecord(
            pkcs12: Data([0x00, 0x01, 0x02, 0x03]), port: 0,
            notAfter: Date(timeIntervalSinceNow: 4000 * 86_400))
        try store.write(try JSONEncoder().encode(corrupt), service: "test.identity")

        let reminted = try TLSIdentity.loadOrCreatePersistent(
            service: "test.identity", commonName: "Test", store: store, now: Date())
        let healed = try TLSIdentity.loadOrCreatePersistent(
            service: "test.identity", commonName: "Test", store: store, now: Date())

        #expect(try reminted.identity.certificateSHA256() != originalPin)               // re-minted
        #expect(try healed.identity.certificateSHA256() == reminted.identity.certificateSHA256())  // self-healed
    }

    /// A bound port round-trips: persistPort then a subsequent load returns it.
    @Test func persistPortRoundTrips() throws {
        let store = InMemoryIdentityStore()
        _ = try TLSIdentity.loadOrCreatePersistent(
            service: "test.identity", commonName: "Test", store: store, now: Date())

        TLSIdentity.persistPort(54321, service: "test.identity", store: store)

        let loaded = try TLSIdentity.loadOrCreatePersistent(
            service: "test.identity", commonName: "Test", store: store, now: Date())
        #expect(loaded.port == 54321)
    }

    /// A stored cert past its (near-)expiry triggers a re-mint → a different pin.
    @Test func expiredRecordIsReminted() throws {
        let store = InMemoryIdentityStore()
        let now = Date()
        let original = try TLSIdentity.loadOrCreatePersistent(
            service: "test.identity", commonName: "Test", store: store, now: now)
        let originalPin = try original.identity.certificateSHA256()

        // Well past the persisted validity horizon.
        let later = now.addingTimeInterval(4000 * 86_400)
        let reminted = try TLSIdentity.loadOrCreatePersistent(
            service: "test.identity", commonName: "Test", store: store, now: later)

        #expect(try reminted.identity.certificateSHA256() != originalPin)
    }

    /// Any keychain failure degrades gracefully to a usable ephemeral identity (no throw),
    /// with no persisted port.
    @Test func keychainFailureFallsBackToEphemeral() throws {
        let result = try TLSIdentity.loadOrCreatePersistent(
            service: "test.identity", commonName: "Test", store: FailingIdentityStore(), now: Date())

        #expect(result.port == nil)
        #expect(!result.persistent)  // keychain unavailable → ephemeral, won't survive restart
        _ = try result.identity.makeSecIdentityT()  // identity is usable
    }
}

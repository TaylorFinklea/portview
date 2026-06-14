import Testing
import Foundation
import Security
@testable import PortviewTransport

/// Exercises the REAL `KeychainIdentityStore` (not an in-memory double) so the actual SecItem
/// add/update/read path — and the full restart round-trip — is covered.
///
/// Uses a unique throwaway service per run and deletes it afterward. If this environment denies
/// keychain access to the (unsigned) test runner, the suite skips rather than failing — the same
/// graceful-degradation contract the feature relies on.
@Suite struct KeychainIdentityStoreTests {
    private func uniqueService() -> String { "dev.finklea.portview.test.\(UUID().uuidString)" }

    private func deleteService(_ service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Returns true if this environment lets the test runner write+read the keychain at all.
    private func keychainUsable(_ service: String) -> Bool {
        let store = KeychainIdentityStore()
        do {
            try store.write(Data([0x01]), service: service)
            return (try? store.read(service: service)) == Data([0x01])
        } catch {
            return false
        }
    }

    @Test func realKeychainRoundTripsPinAndPort() throws {
        let service = uniqueService()
        defer { deleteService(service) }

        guard keychainUsable(service) else { return }  // skip where keychain is inaccessible
        deleteService(service)  // clear the probe value before the real run

        let store = KeychainIdentityStore()
        let first = try TLSIdentity.loadOrCreatePersistent(
            service: service, commonName: "Test", store: store, now: Date())
        #expect(first.persistent)

        TLSIdentity.persistPort(49321, service: service, store: store)

        // Simulate a restart: a brand-new load against the same real keychain item.
        let second = try TLSIdentity.loadOrCreatePersistent(
            service: service, commonName: "Test", store: store, now: Date())

        #expect(try first.identity.certificateSHA256() == second.identity.certificateSHA256())
        #expect(second.port == 49321)
    }
}

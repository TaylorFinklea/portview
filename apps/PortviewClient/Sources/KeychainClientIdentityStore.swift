// SPDX-License-Identifier: Apache-2.0
import Foundation
import PortviewClientCore
import Security

/// Keychain-backed `ClientIdentityStore`: one generic-password item holding the device private
/// key's raw representation, device-only (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) so
/// the identity never migrates to another device via backup/restore — a restored install mints a
/// fresh identity and re-enrolls. Mirrors the host's `KeychainPairingStore`.
struct KeychainClientIdentityStore: ClientIdentityStore {
    private let service = "dev.finklea.portview.client-identity"
    private let account = "device-key"

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
            throw ClientIdentityKeychainError.keychainError(status)
        }
        return data
    }

    func write(_ data: Data) throws {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Unlike the host-side mirrors, the update path re-asserts the accessibility class on every
        // write (Sol review): the identity item must never drift to a migratable/foreground-only
        // class via a historical writer, or backup migration / background re-wake breaks silently.
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(key as CFDictionary, attrs as CFDictionary)
        if update == errSecSuccess { return }
        if update == errSecItemNotFound {
            var add = key
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(add as CFDictionary, nil)
            if status == errSecDuplicateItem {
                let retry = SecItemUpdate(key as CFDictionary, attrs as CFDictionary)
                guard retry == errSecSuccess else { throw ClientIdentityKeychainError.keychainError(retry) }
                return
            }
            guard status == errSecSuccess else { throw ClientIdentityKeychainError.keychainError(status) }
            return
        }
        throw ClientIdentityKeychainError.keychainError(update)
    }
}

enum ClientIdentityKeychainError: Error {
    case keychainError(OSStatus)
}

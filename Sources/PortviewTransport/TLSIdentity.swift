// SPDX-License-Identifier: Apache-2.0
import Foundation
import Security
import CryptoKit

/// Errors generating or importing a TLS identity.
public enum TLSIdentityError: Error {
    case opensslFailed(String)
    case pkcs12ImportFailed(OSStatus)
    case noIdentityInPKCS12
    case secIdentityBridgeFailed
    case keychainError(OSStatus)
}

/// A TLS server identity (certificate + private key) the host presents on the QUIC handshake.
///
/// Ephemeral (`makeEphemeralSelfSigned`) or persisted (`loadOrCreatePersistent`): the persisted
/// path stores the minted PKCS#12 in the keychain so the certificate — and thus the pin a client
/// pins — survives host restarts.
public struct TLSIdentity {
    public let secIdentity: SecIdentity

    /// Serializes `SecPKCS12Import`, which touches the process-global keychain and races
    /// under concurrent imports (e.g. parallel test suites each minting an identity).
    private static let importLock = NSLock()

    public init(secIdentity: SecIdentity) {
        self.secIdentity = secIdentity
    }

    /// Bridge to the Network-framework identity object used in `sec_protocol_options`.
    public func makeSecIdentityT() throws -> sec_identity_t {
        guard let identity = sec_identity_create(secIdentity) else {
            throw TLSIdentityError.secIdentityBridgeFailed
        }
        return identity
    }

    /// SHA-256 of the leaf certificate's DER encoding — the value a client pins.
    /// (In M1 this is encoded into the pairing QR; the client pins it before connecting.)
    public func certificateSHA256() throws -> Data {
        var certificate: SecCertificate?
        let status = SecIdentityCopyCertificate(secIdentity, &certificate)
        guard status == errSecSuccess, let certificate else {
            throw TLSIdentityError.secIdentityBridgeFailed
        }
        let der = SecCertificateCopyData(certificate) as Data
        return Data(SHA256.hash(data: der))
    }

    #if os(macOS)
    /// Service-wide passphrase for the in-process PKCS#12 round-trip. The blob's protection comes
    /// from the keychain item's access control, not this passphrase.
    static let pkcs12Passphrase = "portview"
    /// Persisted-identity validity (~10 years) and the re-mint threshold: regenerate when a stored
    /// cert has less than this remaining, so it never silently expires mid-use.
    static let persistentValidityDays = 3650
    static let remintThreshold: TimeInterval = 30 * 86_400
    /// Serializes the read-mint-write / read-modify-write keychain critical sections so two
    /// concurrent host starts can't race to mint or overwrite the persisted record.
    private static let persistenceLock = NSLock()

    /// Generate a fresh, ephemeral self-signed identity via the system `openssl`, then import it as
    /// a `SecIdentity`. Host-only (macOS): uses `Process`, unavailable on iOS, and only the host
    /// mints an identity. Short-lived; the persisted path (`loadOrCreatePersistent`) uses a long horizon.
    public static func makeEphemeralSelfSigned(commonName: String = "Portview") throws -> TLSIdentity {
        try mintSelfSigned(commonName: commonName, days: 2).identity
    }

    /// Mint a self-signed identity, returning both the `SecIdentity` and the raw PKCS#12 bytes so
    /// callers can persist the blob.
    static func mintSelfSigned(commonName: String, days: Int) throws -> (identity: TLSIdentity, pkcs12: Data) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let keyPath = dir.appendingPathComponent("key.pem").path
        let certPath = dir.appendingPathComponent("cert.pem").path
        let p12Path = dir.appendingPathComponent("identity.p12").path

        try runOpenSSL([
            "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", keyPath, "-out", certPath,
            "-days", "\(days)", "-nodes", "-subj", "/CN=\(commonName)",
        ])
        // Force SHA1/3DES PBE + MAC so Apple's Security framework imports the key cleanly.
        try runOpenSSL([
            "pkcs12", "-export",
            "-inkey", keyPath, "-in", certPath,
            "-out", p12Path, "-passout", "pass:\(pkcs12Passphrase)",
            "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1",
        ])

        let p12Data = try Data(contentsOf: URL(fileURLWithPath: p12Path))
        return (try importPKCS12(p12Data, passphrase: pkcs12Passphrase), p12Data)
    }

    /// Load the persisted host identity, or mint + persist a fresh long-lived one. Keychain failures
    /// degrade to an ephemeral identity (the host always starts); only a total mint failure throws.
    public static func loadOrCreatePersistent(
        service: String,
        commonName: String = "Portview Host"
    ) throws -> PersistentHostIdentity {
        try loadOrCreatePersistent(service: service, commonName: commonName,
                                   store: KeychainIdentityStore(), now: Date())
    }

    static func loadOrCreatePersistent(
        service: String,
        commonName: String,
        store: IdentityRecordStore,
        now: Date
    ) throws -> PersistentHostIdentity {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }

        if let data = try? store.read(service: service),
           let record = try? JSONDecoder().decode(StoredIdentityRecord.self, from: data),
           record.notAfter.timeIntervalSince(now) > remintThreshold,
           let identity = try? importPKCS12(record.pkcs12, passphrase: pkcs12Passphrase) {
            return PersistentHostIdentity(
                identity: identity, port: record.port == 0 ? nil : record.port, persistent: true)
        }

        // Mint fresh and best-effort persist. A failed write (or a corrupted/expired prior record)
        // is overwritten by `store.write` (update-first), so a recoverable keychain self-heals next
        // launch; a write that genuinely fails leaves an ephemeral identity (persistent == false).
        let minted = try mintSelfSigned(commonName: commonName, days: persistentValidityDays)
        let record = StoredIdentityRecord(
            pkcs12: minted.pkcs12,
            port: 0,
            notAfter: now.addingTimeInterval(Double(persistentValidityDays) * 86_400))
        var persisted = false
        if let encoded = try? JSONEncoder().encode(record) {
            do {
                try store.write(encoded, service: service)
                persisted = true
            } catch {
                // Keychain unavailable — run with an ephemeral identity this session.
            }
        }
        return PersistentHostIdentity(identity: minted.identity, port: nil, persistent: persisted)
    }

    /// Persist the actually-bound port into the existing record so the next launch re-requests it.
    /// Best-effort; returns whether the port was stored (false when there's no record or the write
    /// failed, e.g. keychain unavailable).
    @discardableResult
    public static func persistPort(_ port: UInt16, service: String) -> Bool {
        persistPort(port, service: service, store: KeychainIdentityStore())
    }

    @discardableResult
    static func persistPort(_ port: UInt16, service: String, store: IdentityRecordStore) -> Bool {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        guard port != 0,
              let data = try? store.read(service: service),
              var record = try? JSONDecoder().decode(StoredIdentityRecord.self, from: data)
        else { return false }
        record.port = port
        guard let encoded = try? JSONEncoder().encode(record) else { return false }
        do {
            try store.write(encoded, service: service)
            return true
        } catch {
            return false
        }
    }

    /// Import a PKCS#12 blob and extract its identity.
    public static func importPKCS12(_ data: Data, passphrase: String) throws -> TLSIdentity {
        let options: [String: Any] = [kSecImportExportPassphrase as String: passphrase]
        var items: CFArray?
        importLock.lock()
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        importLock.unlock()
        guard status == errSecSuccess else { throw TLSIdentityError.pkcs12ImportFailed(status) }
        guard let array = items as? [[String: Any]],
              let first = array.first,
              let identityRef = first[kSecImportItemIdentity as String]
        else { throw TLSIdentityError.noIdentityInPKCS12 }
        return TLSIdentity(secIdentity: identityRef as! SecIdentity)
    }

    private static func runOpenSSL(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw TLSIdentityError.opensslFailed("openssl \(arguments.first ?? "") failed: \(err)")
        }
    }
    #endif
}

#if os(macOS)
/// A host identity loaded from (or freshly minted into) persistent storage, plus the port the host
/// should re-bind so a saved pairing's `host:port` stays valid across restarts (`nil` until bound).
public struct PersistentHostIdentity {
    public let identity: TLSIdentity
    public let port: UInt16?
    /// Whether the identity is keychain-backed (so its pin survives restarts). `false` means a
    /// keychain failure forced an ephemeral fallback — the pin will change on the next launch.
    public let persistent: Bool
}

/// Storage seam for the persisted identity record (real impl: keychain; tests inject memory).
/// Implementations persist an opaque blob keyed by `service`.
protocol IdentityRecordStore {
    func read(service: String) throws -> Data?
    func write(_ data: Data, service: String) throws
}

/// The persisted record: the PKCS#12 blob, the bound port (0 = not yet bound), and the cert's
/// expiry (set at mint time, so storing it is exact and avoids re-reading cert validity).
struct StoredIdentityRecord: Codable {
    let pkcs12: Data
    var port: UInt16
    let notAfter: Date
}

/// Keychain-backed store: one generic-password item per `service`, device-only, in the (default)
/// file-based login keychain so the signed app reads its own item prompt-free across launches.
struct KeychainIdentityStore: IdentityRecordStore {
    private let account = "identity"

    func read(service: String) throws -> Data? {
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
            throw TLSIdentityError.keychainError(status)
        }
        return data
    }

    func write(_ data: Data, service: String) throws {
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
                // Lost an add race with a concurrent writer — the item now exists; update it.
                let retry = SecItemUpdate(key as CFDictionary, [kSecValueData as String: data] as CFDictionary)
                guard retry == errSecSuccess else { throw TLSIdentityError.keychainError(retry) }
                return
            }
            guard status == errSecSuccess else { throw TLSIdentityError.keychainError(status) }
            return
        }
        throw TLSIdentityError.keychainError(update)
    }
}
#endif

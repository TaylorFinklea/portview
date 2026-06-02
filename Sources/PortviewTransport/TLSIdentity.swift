import Foundation
import Security
import CryptoKit

/// Errors generating or importing a TLS identity.
public enum TLSIdentityError: Error {
    case opensslFailed(String)
    case pkcs12ImportFailed(OSStatus)
    case noIdentityInPKCS12
    case secIdentityBridgeFailed
}

/// A TLS server identity (certificate + private key) the host presents on the QUIC handshake.
///
/// M0: an ephemeral self-signed identity generated at runtime. M1 will persist it and expose
/// its SPKI fingerprint for QR pairing + client pinning (replacing the openssl shell-out with
/// a first-class cert generator).
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
    /// Generate a fresh, ephemeral self-signed identity via the system `openssl`,
    /// then import it as a `SecIdentity`. Host-only (macOS): uses `Process`, which is
    /// unavailable on iOS, and only the host needs to mint an identity.
    public static func makeEphemeralSelfSigned(commonName: String = "Portview") throws -> TLSIdentity {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let keyPath = dir.appendingPathComponent("key.pem").path
        let certPath = dir.appendingPathComponent("cert.pem").path
        let p12Path = dir.appendingPathComponent("identity.p12").path
        let passphrase = "portview"

        try runOpenSSL([
            "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", keyPath, "-out", certPath,
            "-days", "2", "-nodes", "-subj", "/CN=\(commonName)",
        ])
        // Force SHA1/3DES PBE + MAC so Apple's Security framework imports the key cleanly.
        try runOpenSSL([
            "pkcs12", "-export",
            "-inkey", keyPath, "-in", certPath,
            "-out", p12Path, "-passout", "pass:\(passphrase)",
            "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1",
        ])

        let p12Data = try Data(contentsOf: URL(fileURLWithPath: p12Path))
        return try importPKCS12(p12Data, passphrase: passphrase)
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

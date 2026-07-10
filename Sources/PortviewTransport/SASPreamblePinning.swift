// SPDX-License-Identifier: Apache-2.0
import Foundation
import Network
import Security
import CryptoKit

/// Thread-safe holder for a leaf-cert SHA-256 captured during a TLS handshake (the verify block runs
/// on its own queue while the awaiting task blocks on `awaitReady`).
final class CertificateCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    func set(_ value: Data) { lock.lock(); stored = value; lock.unlock() }
    var leafSHA256: Data? { lock.lock(); defer { lock.unlock() }; return stored }
}

enum SASPreambleError: Error { case certNotCaptured }

/// TOFU cert-**capturing** verify for the SAS pairing preamble ONLY.
///
/// It accepts ANY leaf certificate (`complete(true)` unconditionally) and records its SHA-256 so the
/// SAS code can be derived against — and the eventual pinned re-dial pinned to — the cert actually
/// presented. This is DELIBERATELY a separate type from `CertificatePinning`: using it disables
/// pinning, which is only safe on the throwaway preamble connection (trust is decided AFTER, by the
/// SAS code comparison). Keeping it out of `CertificatePinning` and off any `client(...)`/`connect...`
/// pinned API means a copy-paste or autocomplete can't accidentally wire TOFU into a streaming path.
enum SASPreamblePinning {
    static func installCapturing(on options: sec_protocol_options_t, capture: CertificateCapture) {
        sec_protocol_options_set_verify_block(
            options,
            { _, secTrust, complete in
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                   let leaf = chain.first {
                    let der = SecCertificateCopyData(leaf) as Data
                    capture.set(Data(SHA256.hash(data: der)))
                }
                complete(true)  // TOFU: accept any cert; the SAS code binds the captured hash.
            },
            DispatchQueue(label: "portview.sas.capture")
        )
    }
}

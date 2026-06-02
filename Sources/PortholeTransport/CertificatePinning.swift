import Foundation
import Network
import Security
import CryptoKit

/// Shared TLS certificate-pinning verify block used by both the QUIC and TLS parameter builders.
enum CertificatePinning {
    /// Install a verify block on `options` that completes `true` only when the peer's leaf
    /// certificate's DER encoding hashes (SHA-256) to `pinnedCertificateSHA256`.
    static func install(on options: sec_protocol_options_t, pinnedCertificateSHA256: Data) {
        let pin = pinnedCertificateSHA256
        sec_protocol_options_set_verify_block(
            options,
            { _, secTrust, complete in
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                      let leaf = chain.first else {
                    complete(false)
                    return
                }
                let der = SecCertificateCopyData(leaf) as Data
                complete(Data(SHA256.hash(data: der)) == pin)
            },
            DispatchQueue(label: "porthole.tls.verify")
        )
    }
}

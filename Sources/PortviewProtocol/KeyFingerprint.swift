// SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit

/// Shared human-compare view (han.3 design v2): a short fingerprint derived from a device public
/// key, for the enrollment ceremony's out-of-band verification (e.g. comparing on host and client
/// screens). Format is frozen so both sides render an identical string for the same key.
public enum KeyFingerprint {
    /// First 10 bytes of SHA256(publicKey), uppercase hex, grouped `XXXX XXXX XXXX XXXX XXXX`.
    public static func short(forPublicKey publicKey: Data) -> String {
        let digest = SHA256.hash(data: publicKey)
        let hex = digest.prefix(10).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4)
            .map { i -> Substring in
                let start = hex.index(hex.startIndex, offsetBy: i)
                let end = hex.index(start, offsetBy: 4)
                return hex[start..<end]
            }
            .joined(separator: " ")
    }
}

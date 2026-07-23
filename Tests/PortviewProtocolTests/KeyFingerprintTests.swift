// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import CryptoKit
@testable import PortviewProtocol

/// The shared human-compare view (han.3 design v2): a short, easy-to-read hex fingerprint derived
/// from a device public key. Format is frozen so both host and client render an identical string
/// for the same key.
@Suite struct KeyFingerprintTests {
    @Test func frozenVector() {
        // Frozen ONCE via a scratch script: SHA256 of the raw bytes 0x01...0x20 (this fixes the
        // FORMAT, not a real keypair), first 10 bytes, uppercase hex, grouped 4+space.
        let pubkey = Data(1...32)
        #expect(KeyFingerprint.short(forPublicKey: pubkey) == "AE21 6C2E F524 7A37 82C1")
    }

    @Test func formatIs5GroupsOf4UppercaseHex() {
        let pubkey = Data((0..<32).map { UInt8($0) })
        let s = KeyFingerprint.short(forPublicKey: pubkey)
        let regex = try! NSRegularExpression(pattern: "^[0-9A-F]{4}( [0-9A-F]{4}){4}$")
        let range = NSRange(s.startIndex..., in: s)
        #expect(regex.firstMatch(in: s, range: range) != nil)
    }
}

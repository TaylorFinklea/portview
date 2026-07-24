// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Display/persist hygiene for attacker-controlled device names (must-fix 4): strips control and
/// bidi/format characters that could spoof UI, collapses whitespace, and bounds length. Applied
/// ONCE at serveSession entry and reused everywhere the name flows (the enrollment event, the
/// persisted `enroll`, and `.deviceConnected`).
internal enum DeviceNameSanitizer {
    /// Bidi/format scalars not already covered by the Unicode `.control` general category:
    /// LRM/RLM, the embed/override/isolate controls, the Arabic Letter Mark, and line/paragraph
    /// separators (U+2028/U+2029) which must never survive into UI display as they are a
    /// line-injection vector.
    private static let bannedScalars: CharacterSet = {
        var set = CharacterSet(charactersIn: "\u{200E}\u{200F}\u{061C}")
        set.insert(charactersIn: Unicode.Scalar(0x202A)!...Unicode.Scalar(0x202E)!)
        set.insert(charactersIn: Unicode.Scalar(0x2066)!...Unicode.Scalar(0x2069)!)
        set.insert(charactersIn: "\u{2028}\u{2029}")
        return set
    }()

    /// Hard bound on the untrusted wire-supplied name BEFORE any grapheme/whitespace work
    /// (Finding G+, adversarial review): `prefix(64)` below truncates by EXTENDED GRAPHEME
    /// CLUSTER, and a single base scalar followed by an unboundedly long run of combining marks is
    /// ONE grapheme cluster — it sails through that cap as "64 characters" while actually costing
    /// up to ~16 MiB. Capping the INPUT to a fixed UTF-8 byte budget first keeps every downstream
    /// step (filtering, whitespace collapse, grapheme-cluster truncation) bounded regardless of
    /// how pathological the input is.
    private static let maxInputUTF8Bytes = 256

    /// Bound `name` to `maxInputUTF8Bytes` UTF-8 bytes, stopping at a whole-scalar boundary (never
    /// splitting a multi-byte scalar into invalid UTF-8). Iterates `unicodeScalars` — NOT grapheme
    /// clusters — so the cost is proportional to the number of scalars actually kept, never to
    /// however many combining marks trail the input.
    private static func boundToByteBudget(_ name: String) -> String {
        var byteCount = 0
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            let scalarBytes = String(scalar).utf8.count
            guard byteCount + scalarBytes <= maxInputUTF8Bytes else { break }
            byteCount += scalarBytes
            scalars.append(scalar)
        }
        return String(scalars)
    }

    internal static func sanitize(_ name: String) -> String {
        let bounded = boundToByteBudget(name)
        let filteredScalars = bounded.unicodeScalars.filter { scalar in
            !bannedScalars.contains(scalar)
                && scalar.properties.generalCategory != .control
                // Finding G+ (2): `.format`-category scalars — U+FEFF (ZWNBSP/BOM), U+200D (ZWJ),
                // U+00AD (soft hyphen), etc. — survive the `.control`-only filter and are an
                // invisible-char name-spoofing vector.
                && scalar.properties.generalCategory != .format
        }
        let stripped = String(String.UnicodeScalarView(filteredScalars))
        let collapsed = stripped
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let truncated = String(collapsed.prefix(64))
        return truncated.isEmpty ? "(unnamed device)" : truncated
    }
}

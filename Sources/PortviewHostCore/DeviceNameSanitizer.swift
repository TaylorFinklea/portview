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

    internal static func sanitize(_ name: String) -> String {
        let filteredScalars = name.unicodeScalars.filter { scalar in
            !bannedScalars.contains(scalar) && scalar.properties.generalCategory != .control
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

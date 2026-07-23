// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import PortviewHostCore

/// Display/persist hygiene for attacker-controlled device names (must-fix 4). Sanitized ONCE at
/// serveSession entry and reused everywhere the name flows — the enrollment event, the persisted
/// `enroll`, and `.deviceConnected` — so these tests lock down every hygiene invariant it must
/// hold: control-char stripping, bidi/format-char stripping, whitespace collapse, length bound
/// (by grapheme cluster, not scalar or byte), and the empty-name fallback.
@Suite struct DeviceNameSanitizerTests {
    @Test func normalNamePassesThroughUnchanged() {
        #expect(DeviceNameSanitizer.sanitize("Taylor's MacBook Pro") == "Taylor's MacBook Pro")
    }

    @Test func stripsC0AndC1Controls() {
        let input = "A\u{0001}B\u{001F}C\u{007F}D\u{0080}E\u{009F}F"
        #expect(DeviceNameSanitizer.sanitize(input) == "ABCDEF")
    }

    @Test func stripsBidiAndFormatChars() {
        // U+200E/F (LRM/RLM), U+202A-E (embed/override), U+2066-9 (isolate), U+061C (ALM).
        let input =
            "A\u{200E}B\u{200F}C\u{202A}D\u{202B}E\u{202C}F\u{202D}G\u{202E}"
            + "H\u{2066}I\u{2067}J\u{2068}K\u{2069}L\u{061C}M"
        #expect(DeviceNameSanitizer.sanitize(input) == "ABCDEFGHIJKLM")
    }

    @Test func collapsesWhitespaceRunsAndTrims() {
        #expect(DeviceNameSanitizer.sanitize("  Alice's   Mac  \t\n  Pro  ") == "Alice's Mac Pro")
    }

    @Test func truncatesTo64Characters() {
        let input = String(repeating: "x", count: 100)
        let result = DeviceNameSanitizer.sanitize(input)
        #expect(result.count == 64)
        #expect(result == String(repeating: "x", count: 64))
    }

    @Test func truncatesByGraphemeClusterNotScalar() {
        // Family emoji: 4 code points joined by ZWJ (U+200D, not banned) forming ONE Character.
        // Truncating by scalar count would slice mid-cluster and corrupt the emoji; truncating by
        // Character count must not.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        let input = String(repeating: family, count: 70)
        let result = DeviceNameSanitizer.sanitize(input)
        #expect(result.count == 64)
        #expect(result == String(repeating: family, count: 64))
    }

    @Test func emptyOrWhitespaceOnlyFallsBackToUnnamedDevice() {
        #expect(DeviceNameSanitizer.sanitize("") == "(unnamed device)")
        #expect(DeviceNameSanitizer.sanitize("   ") == "(unnamed device)")
        #expect(DeviceNameSanitizer.sanitize("\t\n  ") == "(unnamed device)")
        // Only banned/control chars — nothing survives stripping either.
        #expect(DeviceNameSanitizer.sanitize("\u{200E}\u{200F}\u{061C}") == "(unnamed device)")
    }

    @Test func stripsLineSeparatorAndParagraphSeparator() {
        // U+2028 (LINE SEPARATOR) and U+2029 (PARAGRAPH SEPARATOR) must be stripped directly,
        // never converted to spaces — they are not in the control category but are a line-injection
        // vector if they survive into display UI. This test pins the invariant explicitly.
        #expect(DeviceNameSanitizer.sanitize("A\u{2028}B\u{2029}C") == "ABC")
    }
}

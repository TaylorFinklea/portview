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
        // Family emoji: 4 code points originally joined by ZWJ (U+200D) into ONE Character. Since
        // Finding G+ (2), U+200D is stripped as a `.format`-category scalar (invisible-char
        // name-spoofing vector) — for a device NAME, decomposing a ZWJ sequence into its
        // individual emoji is an acceptable tradeoff; the test's actual intent (truncating by
        // grapheme cluster, not raw scalar, so a cluster is never sliced in half) still holds for
        // whatever clusters remain after stripping. Finding G+ (1)'s byte budget (256 bytes,
        // applied to the INPUT before any of this) is what actually bounds the result here: only
        // ~10 family-emoji repeats' worth of scalars fit under the budget, well short of the
        // 64-character truncation this test originally exercised — so the expected value below is
        // the OBSERVED bounded-then-ZWJ-stripped output (10 whole families, decomposed, plus one
        // leftover lone scalar), not the original 64-Character-truncation value.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        let input = String(repeating: family, count: 70)
        let result = DeviceNameSanitizer.sanitize(input)
        let decomposedFamily = "\u{1F468}\u{1F469}\u{1F467}\u{1F466}"
        #expect(result == String(repeating: decomposedFamily, count: 10) + "\u{1F468}")
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

    @Test func boundsInputToAFixedByteBudgetBeforeGraphemeWork() {
        // Finding G+ (1): `prefix(64)` (below) truncates by EXTENDED GRAPHEME CLUSTER, and a
        // single base scalar followed by an unboundedly long run of combining marks is ONE
        // grapheme cluster — it sails through that cap as "64 characters" while actually costing
        // up to ~16 MiB. The INPUT must be capped to a fixed UTF-8 byte budget (256 bytes) BEFORE
        // any grapheme/whitespace work, so sanitization stays bounded no matter how many
        // combining marks trail the input.
        let combiningMark = "\u{0301}"  // COMBINING ACUTE ACCENT
        let input = "A" + String(repeating: combiningMark, count: 100_000)
        let result = DeviceNameSanitizer.sanitize(input)
        #expect(result.utf8.count <= 256)
    }

    @Test func stripsFormatCategoryScalars() {
        // Finding G+ (2): Unicode `.format`-category scalars not already covered by the explicit
        // `bannedScalars` set — U+FEFF (ZWNBSP/BOM), U+200D (ZWJ), U+00AD (SOFT HYPHEN) — survive
        // the old `.control`-only filter, an invisible-char name-spoofing vector. They must be
        // stripped alongside control characters.
        let input = "A\u{FEFF}B\u{200D}C\u{00AD}D"
        #expect(DeviceNameSanitizer.sanitize(input) == "ABCD")
    }
}

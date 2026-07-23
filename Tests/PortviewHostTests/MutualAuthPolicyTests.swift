// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import PortviewHostCore
import PortviewTransport

/// The host-LOCAL mutual-auth rollout policy (spec §4-RESOLVED). Load-bearing invariants: the
/// policy is never wire-negotiated, `.required` is absolute, and bootstrap tightens one-way —
/// by expiry, by an enrolled device, OR by an unreadable store (fail closed) — and never opens on
/// a state it cannot positively verify as empty.
@Suite struct MutualAuthPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func requiredIsAlwaysRequired() {
        for enrollment in [EnrollmentSnapshot.empty, .populated, .unreadable] {
            #expect(MutualAuthPolicy.required.effectiveMode(now: now, enrollment: enrollment) == .required)
        }
    }

    @Test func bootstrapAdmitsLegacyOnlyWhileVerifiedEmptyAndUnexpired() {
        let policy = MutualAuthPolicy.legacyBootstrap(expiresAt: now.addingTimeInterval(60))
        #expect(policy.effectiveMode(now: now, enrollment: .empty) == .bootstrap)
        #expect(policy.effectiveMode(now: now.addingTimeInterval(60), enrollment: .empty) == .required)
        #expect(policy.effectiveMode(now: now.addingTimeInterval(3600), enrollment: .empty) == .required)
    }

    @Test func bootstrapAutoPromotesOnFirstEnrollment() {
        // One-directional tightening: only auth-capable clients can enroll, so once ANY device is
        // enrolled the escape hatch has served its purpose and the gate becomes required — even
        // long before the expiry date.
        let policy = MutualAuthPolicy.legacyBootstrap(expiresAt: now.addingTimeInterval(86_400))
        #expect(policy.effectiveMode(now: now, enrollment: .populated) == .required)
    }

    @Test func unreadableStoreFailsClosedToRequired() {
        // Sol han.1 review (CRITICAL): a store read error must NOT be read as "verified empty →
        // bootstrap open." An unreadable enrollment store forces `.required` — the OPPOSITE of the
        // fail-open the old `!list().isEmpty` gave (list() collapses a read error to empty).
        let policy = MutualAuthPolicy.legacyBootstrap(expiresAt: now.addingTimeInterval(86_400))
        #expect(policy.effectiveMode(now: now, enrollment: .unreadable) == .required)
    }
}

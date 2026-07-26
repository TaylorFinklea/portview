// SPDX-License-Identifier: Apache-2.0
import XCTest

/// PROVENANCE → ROW STATE (Sol pass 4 F1/F3). The security regression these cover: `PairingStore`
/// handed the app one untagged pending set that unioned durably-recorded revocation intents with this
/// process's failed-enrollment fence; the app then defaulted the fenced row to the ordinary
/// "revoke incomplete" state, whose Retry ran a durable, destructive `PairingStore.revoke`. A device
/// nobody ever asked to remove became destroyable by one click.
///
/// `DeviceStatusResolver` is compiled straight into this logic-test bundle (no app host, no keychain,
/// no LAContext) — see `project.yml`. It EXPOSES the decision; it grants no authority, so nothing here
/// weakens a production gate.
final class DeviceStatusResolverTests: XCTestCase {
    private let fenced = "K"
    private let other = "J"

    // MARK: - the F1 regression

    func testAnEnrollmentFenceIsNeverARevokeRow() {
        let resolver = DeviceStatusResolver(enrollmentFences: [fenced])
        XCTAssertEqual(resolver.status(fenced), .enrollmentUnverified)
        // Said the other way round, because THIS is the state that was reachable before the fix and
        // that routes to an ungated destructive Retry:
        XCTAssertNotEqual(resolver.status(fenced), .revokeIncomplete(.durable))
    }

    func testAnEnrollmentFenceOffersNoDestructiveRetry() {
        let actions = DeviceStatusResolver(enrollmentFences: [fenced]).status(fenced).recoveryActions
        XCTAssertFalse(actions.contains(.retryRevoke),
                       "a device that was never revoked must not offer to continue a revoke")
        XCTAssertTrue(actions.contains(.finishPairing))
    }

    func testAFenceOnOneDeviceLeavesEveryOtherRowAuthorized() {
        let resolver = DeviceStatusResolver(enrollmentFences: [fenced])
        XCTAssertEqual(resolver.status(other), .authorized)
    }

    // MARK: - revokeDurability defaulting

    /// The default that made the regression exploitable: "no durability warning recorded" ⇒ `.durable`
    /// ⇒ the plain revoke-incomplete row. It is correct ONLY once revoke provenance is established —
    /// a retained lease or a durably recorded intent — and must never be applied to a bare fence.
    func testMissingWarningDefaultsToDurableOnlyUnderRevokeProvenance() {
        XCTAssertEqual(DeviceStatusResolver(leaseHeld: [fenced]).status(fenced), .revokeIncomplete(.durable))
        XCTAssertEqual(DeviceStatusResolver(durableIntents: [fenced]).status(fenced), .revokeIncomplete(.durable))
        // Same empty warning map, no revoke provenance → NOT the durable revoke row.
        XCTAssertEqual(DeviceStatusResolver(enrollmentFences: [fenced]).status(fenced), .enrollmentUnverified)
    }

    func testNoProvenanceAtAllIsAuthorized() {
        XCTAssertEqual(DeviceStatusResolver().status(fenced), .authorized)
    }

    func testAClassifiedRevokeFailureAloneIsRevokeProvenance() {
        // `noteRevokeDurability` can record a warning for a device whose lease was already released
        // (a post-restart Retry that fails again). That is still an authenticated revoke.
        let resolver = DeviceStatusResolver(durabilityWarnings: [fenced: .notDurable])
        XCTAssertEqual(resolver.status(fenced), .revokeIncomplete(.notDurable))
    }

    /// Sol pass 3 N1's split, now living in the pure resolver: an UNKNOWN durability hedges only when
    /// the last known durable set does NOT list the device; when it does, the fence was last seen
    /// durable and the row must not raise re-admission at all.
    func testUnknownDurabilitySplitsOnTheLastKnownDurableSet() {
        let noIntent = DeviceStatusResolver(durabilityWarnings: [fenced: .unverified])
        XCTAssertEqual(noIntent.status(fenced), .revokeIncomplete(.unverified))
        let intentLastSeen = DeviceStatusResolver(durableIntents: [fenced],
                                                  durabilityWarnings: [fenced: .unverified])
        XCTAssertEqual(intentLastSeen.status(fenced), .revokeIncomplete(.unverifiedFenceLastSeen))
    }

    /// Disjointness (`PairingStore.pendingRevocations` keeps the sets apart, and the resolver agrees):
    /// a durably recorded intent proves an authenticated revoke WAS requested, so it outranks a fence
    /// on the same id and the row stays a revoke row.
    func testADurableIntentOutranksAFenceForTheSameDevice() {
        let resolver = DeviceStatusResolver(durableIntents: [fenced], enrollmentFences: [fenced])
        XCTAssertEqual(resolver.status(fenced), .revokeIncomplete(.durable))
    }
}

// SPDX-License-Identifier: Apache-2.0
import XCTest

/// RECOVERY-ACTION AUTHORIZATION ROUTING (Sol pass 4 F1/F3). `MenuBarHostView` builds its row buttons
/// from `DeviceRowStatus.recoveryActions` and sends any action whose `requiresConfirmation` is true to
/// the confirmation dialog before it can reach the model — so this table is load-bearing, not
/// documentation. `HostAppModel` runs the `LAContext` evaluation itself; nothing here can perform or
/// skip it, and these tests assert the ROUTING, never that a gate was bypassed.
final class RecoveryActionRoutingTests: XCTestCase {

    /// The regression, stated as routing: a failed enrollment carries an authenticated ADMIT decision
    /// and no authenticated REVOKE decision, so its row may not offer to continue a revoke.
    func testEnrollmentFenceNeverOffersTheDestructiveRetry() {
        XCTAssertEqual(DeviceRowStatus.enrollmentUnverified.recoveryActions, [.finishPairing, .revoke])
        XCTAssertFalse(DeviceRowStatus.enrollmentUnverified.recoveryActions.contains(.retryRevoke))
    }

    /// The fitting recovery for a fence: finish the admit that never completed. It is not destructive
    /// — it destroys no enrollment — but it IS authorization-granting, so it still owes local presence.
    func testFinishPairingIsNonDestructiveAndStillRequiresLocalPresence() {
        XCTAssertFalse(RecoveryAction.finishPairing.isDestructive)
        XCTAssertFalse(RecoveryAction.finishPairing.requiresConfirmation)
        XCTAssertTrue(RecoveryAction.finishPairing.requiresLocalPresence)
    }

    /// Every destructive action carries BOTH gates — the confirmation dialog (product decision 1) and
    /// the LAContext check. Retry is destructive: it runs the same durable `PairingStore.revoke`.
    func testEveryDestructiveActionRequiresConfirmationAndLocalPresence() {
        let destructive = RecoveryAction.allCases.filter(\.isDestructive)
        XCTAssertEqual(Set(destructive), Set([.revoke, .retryRevoke]))
        for action in destructive {
            XCTAssertTrue(action.requiresConfirmation, "\(action) must pass the confirmation dialog")
            XCTAssertTrue(action.requiresLocalPresence, "\(action) must pass the LAContext gate")
        }
    }

    /// No row action of any kind is reachable without proven local presence — a connected authenticated
    /// peer can inject a click on the host's screen (han.3 "GLM2"), and both directions matter: two of
    /// these remove access and two grant it back.
    func testNoStatusOffersAnyActionWithoutLocalPresence() {
        for status in DeviceRowStatus.all {
            for action in status.recoveryActions {
                XCTAssertTrue(action.requiresLocalPresence, "\(action) offered by \(status) is ungated")
            }
        }
    }

    func testRevokeIncompleteOffersRetryAndCancelForEveryDurability() {
        for durability in RevokeDurability.allCases {
            XCTAssertEqual(DeviceRowStatus.revokeIncomplete(durability).recoveryActions,
                           [.retryRevoke, .cancelRevoke])
        }
    }

    func testAnAuthorizedRowOffersOnlyTheConfirmedRevoke() {
        XCTAssertEqual(DeviceRowStatus.authorized.recoveryActions, [.revoke])
        XCTAssertTrue(RecoveryAction.revoke.requiresConfirmation)
    }

    /// The dialog copy exists for EXACTLY the actions that must pass the dialog — so a destructive
    /// action can neither reach the user with no wording nor a non-destructive one acquire a dialog by
    /// accident — and Retry does not borrow Revoke's "it will lose access immediately", which describes
    /// something that already happened for a device that is blocked.
    func testConfirmationCopyExistsForExactlyTheConfirmedActions() {
        for action in RecoveryAction.allCases {
            XCTAssertEqual(action.confirmation != nil, action.requiresConfirmation, "\(action)")
        }
        XCTAssertNotEqual(RecoveryAction.retryRevoke.confirmation?.message,
                          RecoveryAction.revoke.confirmation?.message)
        XCTAssertNotEqual(RecoveryAction.retryRevoke.confirmation?.verb,
                          RecoveryAction.revoke.confirmation?.verb)
    }

    /// The two re-admit actions stay distinct so their buttons and their LAContext reasons can each
    /// tell the truth about the row they came from; a shared label would put "Cancel" on a row where
    /// nothing was ever cancelled.
    func testTheTwoReAdmitActionsAreLabelledDistinctly() {
        XCTAssertNotEqual(RecoveryAction.cancelRevoke.title, RecoveryAction.finishPairing.title)
        XCTAssertFalse(RecoveryAction.cancelRevoke.isDestructive)
        XCTAssertTrue(RecoveryAction.allCases.allSatisfy { !$0.title.isEmpty })
    }
}

// SPDX-License-Identifier: Apache-2.0
import XCTest

/// ROW STATE → COPY (Sol pass 4 F2/F3). The contradiction these close: the paired-device row already
/// distinguished `.unverified` from `.unverifiedFenceLastSeen` and suppressed re-admission copy for
/// the latter, but the activity-log line was built separately from the raw warning and appended a
/// categorical "MAY regain access if Portview restarts" for BOTH. In N1's exact counterexample — an
/// earlier attempt left a durable intent, Retry cannot re-read it, the cached pending set still lists
/// the device — the row said "couldn't re-check" while the main window's log simultaneously warned of
/// restart re-admission.
final class DeviceStatusCopyTests: XCTestCase {
    private let deviceName = "iPhone"

    /// Does this string assert the device gets (or may get) its access back? Deliberately matched on
    /// "regain" rather than "restart": the durable row legitimately says "blocked even if Portview
    /// restarts", which is the OPPOSITE claim.
    private func claimsReAdmission(_ text: String?) -> Bool {
        text?.lowercased().contains("regain") ?? false
    }

    /// THE F2 invariant, over every status: the row warning and the activity-log line agree about
    /// restart re-admission, and both agree with the status's own `restartClaim`. There is no status
    /// left in which one surface can say a device may come back while the other says it cannot.
    func testRowAndLogNeverDisagreeAboutRestartReAdmission() {
        for status in DeviceRowStatus.all {
            let row = DeviceStatusCopy.rowWarning(status)
            let log = DeviceStatusCopy.logLine(status, deviceName: deviceName)
            let permitted = status.restartClaim != .silent
            XCTAssertEqual(claimsReAdmission(row), permitted, "row copy for \(status): \(row ?? "nil")")
            XCTAssertEqual(claimsReAdmission(log), permitted, "log copy for \(status): \(log ?? "nil")")
        }
    }

    /// N1's counterexample, pinned by name so a regression names itself.
    func testFenceLastSeenDurableClaimsReAdmissionInNeitherSurface() {
        let status = DeviceRowStatus.revokeIncomplete(.unverifiedFenceLastSeen)
        XCTAssertFalse(claimsReAdmission(DeviceStatusCopy.rowWarning(status)))
        XCTAssertFalse(claimsReAdmission(DeviceStatusCopy.logLine(status, deviceName: deviceName)))
        // …and it still says the check failed, rather than going silent about a real problem.
        XCTAssertEqual(DeviceStatusCopy.rowWarning(status),
                       "couldn't re-check the saved revoke — the pairing store is unreadable")
    }

    /// The proven case is the one place a categorical claim is allowed — in BOTH surfaces.
    func testProvenNotDurableStatesReAdmissionInBothSurfaces() {
        let status = DeviceRowStatus.revokeIncomplete(.notDurable)
        XCTAssertTrue(claimsReAdmission(DeviceStatusCopy.rowWarning(status)))
        XCTAssertTrue(claimsReAdmission(DeviceStatusCopy.logLine(status, deviceName: deviceName)))
    }

    /// F1(b): a process-only fence must not borrow the revoke row's copy. It is a pairing that never
    /// finished, and both surfaces must say so.
    func testEnrollmentFenceCopyDescribesTheFailedPairingNotARevoke() {
        let status = DeviceRowStatus.enrollmentUnverified
        let row = try? XCTUnwrap(DeviceStatusCopy.rowWarning(status))
        let line = try? XCTUnwrap(DeviceStatusCopy.rowStatusLine(status))
        let log = try? XCTUnwrap(DeviceStatusCopy.logLine(status, deviceName: deviceName))
        XCTAssertTrue(row?.contains("pairing") ?? false, "row warning: \(row ?? "nil")")
        XCTAssertTrue(line?.contains("pairing") ?? false, "status line: \(line ?? "nil")")
        XCTAssertTrue(log?.contains("pairing") ?? false, "log line: \(log ?? "nil")")
        // It must never render as the ordinary incomplete-revoke row…
        XCTAssertNotEqual(line, DeviceStatusCopy.rowStatusLine(.revokeIncomplete(.durable)))
        // …nor claim anything about a restart, which is not what a fence is about.
        XCTAssertFalse(claimsReAdmission(row))
        XCTAssertFalse(claimsReAdmission(log))
    }

    /// An authorized row says nothing at all — no leftover warning from a status it is not in.
    func testAuthorizedRowProducesNoCopy() {
        XCTAssertNil(DeviceStatusCopy.rowWarning(.authorized))
        XCTAssertNil(DeviceStatusCopy.rowStatusLine(.authorized))
        XCTAssertNil(DeviceStatusCopy.logLine(.authorized, deviceName: deviceName))
    }

    /// A warning the log filter drops is a warning nobody reads. `ContentView.displayedLog` hides any
    /// line at or above `activityLogCharacterLimit`, and the pre-fix `.unverified` line exceeded it
    /// for any device name longer than about six characters — so the loudest warning in the feature
    /// silently vanished for a device called "Taylor's iPhone".
    func testEveryLogLineSurvivesTheActivityLogFilterForALongDeviceName() {
        // Pin the SANITIZER'S ACTUAL CONTRACT, not a comfortable sample. `DeviceNameSanitizer`
        // truncates to 64 grapheme clusters, so 64 is the longest name production can ever hand us —
        // testing 24 proved only that the line fits for short names (Sol pass 5). A realistic
        // "Taylor's Personal iPhone 17 Pro Max" is 35 and was still being silently dropped.
        for count in [24, 35, 64] {
            let longName = String(repeating: "M", count: count)
            for status in DeviceRowStatus.all {
                guard let line = DeviceStatusCopy.logLine(status, deviceName: longName) else { continue }
                XCTAssertLessThan(line.count, DeviceStatusCopy.activityLogCharacterLimit,
                                  "log line for \(status) at name length \(count) is dropped by the activity-log filter: \(line)")
                XCTAssertFalse(line.contains("\n"), "multi-line log entries are filtered out too")
            }
        }
    }

    /// Fitting the line must not silently amputate the name to nothing — the user has to be able to
    /// tell WHICH device the warning is about.
    func testAFittedLogLineStillIdentifiesTheDevice() {
        let longName = String(repeating: "M", count: 64)
        for status in DeviceRowStatus.all {
            guard let line = DeviceStatusCopy.logLine(status, deviceName: longName) else { continue }
            XCTAssertTrue(line.contains(String(repeating: "M", count: 12)),
                          "log line for \(status) no longer identifies the device: \(line)")
        }
    }

    /// Every status that denies a device says SOMETHING beside the buttons — a silently denied row
    /// with no explanation is the reassuring-direction lie this whole feature exists to eliminate.
    func testEveryDenyingStatusHasAStatusLine() {
        for status in DeviceRowStatus.all where status != .authorized {
            XCTAssertNotNil(DeviceStatusCopy.rowStatusLine(status), "no status line for \(status)")
            XCTAssertNotNil(DeviceStatusCopy.logLine(status, deviceName: deviceName), "no log line for \(status)")
        }
    }
}

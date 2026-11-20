// SPDX-License-Identifier: Apache-2.0
import XCTest

final class MenuBarSettingsRoutingTests: XCTestCase {
    func testRememberedDisplayStillAttachedIsSelected() {
        XCTAssertEqual(HostSettingsCoordinator.displaySelection(preferred: 7, available: [3, 7]), 7)
    }

    func testUnavailableRememberedDisplayRendersAsAutomatic() {
        XCTAssertNil(HostSettingsCoordinator.displaySelection(preferred: 9, available: [3, 7]))
        XCTAssertNil(HostSettingsCoordinator.displaySelection(preferred: 9, available: []))
    }

    func testNoPreferenceIsAutomatic() {
        XCTAssertNil(HostSettingsCoordinator.displaySelection(preferred: nil, available: [3, 7]))
    }

    func testPrivacyDefaultsAppearOff() {
        XCTAssertFalse(HostPreferences.defaults.clipboardEnabled)
        XCTAssertFalse(HostPreferences.defaults.fileTransferEnabled)
    }
}

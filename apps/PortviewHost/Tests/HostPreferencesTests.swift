// SPDX-License-Identifier: Apache-2.0
import XCTest

@MainActor
final class HostPreferencesTests: XCTestCase {
    private var suiteName = ""
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "portview.host.tests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        suite = nil
        super.tearDown()
    }

    func testPrivacySensitiveDefaultsAreOff() {
        XCTAssertFalse(HostPreferences.defaults.clipboardEnabled)
        XCTAssertFalse(HostPreferences.defaults.fileTransferEnabled)
        XCTAssertNil(HostPreferences.defaults.preferredPort)
        XCTAssertNil(HostPreferences.defaults.preferredDisplayID)
    }

    func testRoundTripPreservesPortAndDisplay() throws {
        let value = HostPreferences(
            preferredPort: 7443, preferredDisplayID: 42,
            clipboardEnabled: true, fileTransferEnabled: false)
        XCTAssertEqual(try JSONDecoder().decode(HostPreferences.self,
            from: JSONEncoder().encode(value)), value)
    }

    func testFreshStoreStartsWithDefaults() {
        XCTAssertEqual(HostPreferencesStore(defaults: suite).preferences, .defaults)
    }

    func testChangesWriteThroughAndReloadInNewStore() {
        let store = HostPreferencesStore(defaults: suite)
        store.preferences.preferredPort = 9000
        store.preferences.clipboardEnabled = true
        let reloaded = HostPreferencesStore(defaults: suite)
        XCTAssertEqual(reloaded.preferences.preferredPort, 9000)
        XCTAssertTrue(reloaded.preferences.clipboardEnabled)
        XCTAssertFalse(reloaded.preferences.fileTransferEnabled)
    }

    func testCorruptDataFallsBackToDefaults() {
        suite.set(Data("not json".utf8), forKey: HostPreferencesStore.defaultsKey)
        XCTAssertEqual(HostPreferencesStore(defaults: suite).preferences, .defaults)
    }

    // MARK: coordinator

    private final class FakeLogin: LaunchAtLoginControlling {
        var status: LaunchAtLoginStatus = .disabled
        var failure: Error?
        private(set) var calls: [Bool] = []
        func setEnabled(_ enabled: Bool) throws {
            calls.append(enabled)
            if let failure { throw failure }
            status = enabled ? .enabled : .disabled
        }
    }

    private struct Boom: LocalizedError { var errorDescription: String? { "boom" } }

    private func makeCoordinator(_ fake: FakeLogin) -> HostSettingsCoordinator {
        HostSettingsCoordinator(store: HostPreferencesStore(defaults: suite), launchAtLogin: fake)
    }

    func testCoordinatorReportsControllersCurrentStatus() {
        let fake = FakeLogin()
        fake.status = .requiresApproval
        XCTAssertEqual(makeCoordinator(fake).launchAtLogin, .requiresApproval)
    }

    func testEnableCallsControllerOnceAndReflectsState() {
        let fake = FakeLogin()
        let c = makeCoordinator(fake)
        c.setLaunchAtLogin(true)
        XCTAssertEqual(fake.calls, [true])
        XCTAssertEqual(c.launchAtLogin, .enabled)
        XCTAssertNil(c.launchAtLoginError)
    }

    func testFailedTransitionSurfacesErrorAndKeepsRealState() {
        let fake = FakeLogin()
        fake.failure = Boom()
        let c = makeCoordinator(fake)
        c.setLaunchAtLogin(true)
        XCTAssertEqual(fake.calls, [true])
        XCTAssertEqual(c.launchAtLogin, .disabled)
        XCTAssertTrue(c.launchAtLoginError?.contains("boom") == true)
    }

    func testSuccessfulRetryClearsError() {
        let fake = FakeLogin()
        fake.failure = Boom()
        let c = makeCoordinator(fake)
        c.setLaunchAtLogin(true)
        fake.failure = nil
        c.setLaunchAtLogin(true)
        XCTAssertNil(c.launchAtLoginError)
        XCTAssertEqual(c.launchAtLogin, .enabled)
    }

    func testPortValidation() {
        let c = makeCoordinator(FakeLogin())
        XCTAssertTrue(c.commitPort(text: "7443"))
        XCTAssertEqual(c.store.preferences.preferredPort, 7443)
        for bad in ["0", "65536", "abc", "-1", "12x", "99999999"] {
            XCTAssertFalse(c.commitPort(text: bad), bad)
            XCTAssertNotNil(c.portError, bad)
            XCTAssertEqual(c.store.preferences.preferredPort, 7443, "invalid \(bad) must not persist")
        }
        XCTAssertTrue(c.commitPort(text: "65535"))
        XCTAssertEqual(c.store.preferences.preferredPort, 65535)
        XCTAssertTrue(c.commitPort(text: "  "))
        XCTAssertNil(c.store.preferences.preferredPort)
        XCTAssertNil(c.portError)
        XCTAssertNil(HostPreferencesStore(defaults: suite).preferences.preferredPort)
    }
}

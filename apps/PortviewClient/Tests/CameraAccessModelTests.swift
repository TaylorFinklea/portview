// SPDX-License-Identifier: Apache-2.0
import XCTest

@testable import PortviewClient

/// Camera permission state machine. Pure fakes: no AVCaptureSession, no TCC, no Settings.
@MainActor
final class CameraAccessModelTests: XCTestCase {
    private final class Fake {
        var status: CameraAuthorizationStatus
        var hasCamera = true
        var grantOnRequest = true
        var requestCount = 0
        var settingsOpened = 0

        init(status: CameraAuthorizationStatus) { self.status = status }

        var client: CameraAuthorizationClient {
            CameraAuthorizationClient(
                status: { self.status },
                hasCamera: { self.hasCamera },
                requestAccess: {
                    self.requestCount += 1
                    self.status = self.grantOnRequest ? .authorized : .denied
                    return self.grantOnRequest
                },
                openSettings: { self.settingsOpened += 1 })
        }
    }

    func testAuthorizedStartsScanner() async {
        let fake = Fake(status: .authorized)
        let model = CameraAccessModel(client: fake.client)
        await model.start()
        XCTAssertEqual(model.state, .authorized)
        XCTAssertEqual(fake.requestCount, 0)
    }

    func testNotDeterminedRequestsOnceAndAuthorizes() async {
        let fake = Fake(status: .notDetermined)
        let model = CameraAccessModel(client: fake.client)
        await model.start()
        await model.start()
        XCTAssertEqual(model.state, .authorized)
        XCTAssertEqual(fake.requestCount, 1)
    }

    func testNotDeterminedRefusedBecomesDenied() async {
        let fake = Fake(status: .notDetermined)
        fake.grantOnRequest = false
        let model = CameraAccessModel(client: fake.client)
        await model.start()
        XCTAssertEqual(model.state, .denied)
        XCTAssertEqual(fake.requestCount, 1)
    }

    func testRequestThatLeavesStatusUndeterminedNeverRerequests() async {
        let fake = Fake(status: .notDetermined)
        let client = CameraAuthorizationClient(
            status: { fake.status }, hasCamera: { true },
            requestAccess: { fake.requestCount += 1; return false },
            openSettings: {})
        let model = CameraAccessModel(client: client)
        await model.start()
        await model.start()
        XCTAssertEqual(fake.requestCount, 1)
        XCTAssertNotEqual(model.state, .authorized)
    }

    func testDeniedDoesNotRequestAndSettingsOnlyOnExplicitCall() async {
        let fake = Fake(status: .denied)
        let model = CameraAccessModel(client: fake.client)
        await model.start()
        XCTAssertEqual(model.state, .denied)
        XCTAssertEqual(fake.requestCount, 0)
        XCTAssertEqual(fake.settingsOpened, 0)
        model.openSettings()
        XCTAssertEqual(fake.settingsOpened, 1)
    }

    func testNoCameraDeviceIsUnavailable() async {
        let fake = Fake(status: .authorized)
        fake.hasCamera = false
        let model = CameraAccessModel(client: fake.client)
        await model.start()
        XCTAssertEqual(model.state, .unavailable)
    }

    func testDeniedThenSettingsGrantThenForegroundRefreshAuthorizes() async {
        let fake = Fake(status: .denied)
        let model = CameraAccessModel(client: fake.client)
        await model.start()
        XCTAssertEqual(model.state, .denied)
        fake.status = .authorized
        model.refresh()
        XCTAssertEqual(model.state, .authorized)
        XCTAssertEqual(fake.requestCount, 0)
    }

    func testRefreshNeverRepromptsFromNotDetermined() async {
        let fake = Fake(status: .notDetermined)
        let model = CameraAccessModel(client: fake.client)
        model.refresh()
        XCTAssertEqual(fake.requestCount, 0)
    }

    func testAuthorizedSetupFailureBecomesUnavailableAndSticksOnRefresh() async {
        let fake = Fake(status: .authorized)
        let model = CameraAccessModel(client: fake.client)
        await model.start()
        model.scannerFailed()
        XCTAssertEqual(model.state, .unavailable)
        model.refresh()
        XCTAssertEqual(model.state, .unavailable)
    }

    func testRevokedWhileAuthorizedMovesToDeniedOnRefresh() async {
        let fake = Fake(status: .authorized)
        let model = CameraAccessModel(client: fake.client)
        await model.start()
        fake.status = .denied
        model.refresh()
        XCTAssertEqual(model.state, .denied)
    }
}

// SPDX-License-Identifier: Apache-2.0
import XCTest
import PortviewTransport

@testable import PortviewClient

/// `portview://pair` URL routing. Pure: no session, no network, no system surfaces.
final class PairingURLRouterTests: XCTestCase {
    /// A real-length pin (32 bytes = 64 hex chars) — the only kind `SessionViewModel` will dial.
    private let pin = String(repeating: "ab", count: 32)

    private func url(_ s: String) -> URL { URL(string: s)! }

    func testValidURLYieldsPayload() {
        let payload = PairingURLRouter.payload(
            from: url("portview://pair?host=127.0.0.1&port=7443&pin=\(pin)&name=Mac"))
        XCTAssertEqual(payload, PairingPayload(host: "127.0.0.1", port: 7443, pinHex: pin, name: "Mac"))
    }

    func testNameIsOptional() {
        let payload = PairingURLRouter.payload(from: url("portview://pair?host=10.0.0.2&port=7443&pin=\(pin)"))
        XCTAssertEqual(payload?.name, nil)
        XCTAssertEqual(payload?.host, "10.0.0.2")
    }

    func testMatchesTheSingleParser() {
        let s = "portview://pair?host=127.0.0.1&port=7443&pin=\(pin)&name=Mac"
        XCTAssertEqual(PairingURLRouter.payload(from: url(s)), PairingPayload(urlString: s))
    }

    /// `abcdef` parses fine in `PairingPayload` but `SessionViewModel` requires a 32-byte pin and
    /// would set `.failed`; the router must reject it before any session state is touched.
    func testShortPinRejected() {
        XCTAssertNil(PairingURLRouter.payload(from: url("portview://pair?host=127.0.0.1&port=7443&pin=abcdef")))
    }

    func testNonHexPinRejected() {
        let bad = String(repeating: "zz", count: 32)
        XCTAssertNil(PairingURLRouter.payload(from: url("portview://pair?host=127.0.0.1&port=7443&pin=\(bad)")))
    }

    func testOverlongPinRejected() {
        let long = String(repeating: "ab", count: 33)
        XCTAssertNil(PairingURLRouter.payload(from: url("portview://pair?host=127.0.0.1&port=7443&pin=\(long)")))
    }

    func testWrongSchemeRejected() {
        XCTAssertNil(PairingURLRouter.payload(from: url("https://pair?host=127.0.0.1&port=7443&pin=\(pin)")))
    }

    func testWrongHostRejected() {
        XCTAssertNil(PairingURLRouter.payload(from: url("portview://other?host=127.0.0.1&port=7443&pin=\(pin)")))
    }

    func testMissingPortRejected() {
        XCTAssertNil(PairingURLRouter.payload(from: url("portview://pair?host=127.0.0.1&pin=\(pin)")))
    }

    func testOverflowedPortRejected() {
        XCTAssertNil(PairingURLRouter.payload(from: url("portview://pair?host=127.0.0.1&port=70000&pin=\(pin)")))
    }

    func testMalformedURLRejected() {
        XCTAssertNil(PairingURLRouter.payload(from: url("portview:pair")))
        XCTAssertNil(PairingURLRouter.payload(from: url("portview://pair")))
    }

    // MARK: - Presentation decision

    func testIdleWithNothingUpPrompts() {
        XCTAssertEqual(PairingURLRouter.decision(sessionActive: false, presentationBlocking: false), .prompt)
    }

    func testWalkthroughOrSheetUpQueues() {
        XCTAssertEqual(PairingURLRouter.decision(sessionActive: false, presentationBlocking: true), .queue)
    }

    func testActiveSessionIgnores() {
        XCTAssertEqual(PairingURLRouter.decision(sessionActive: true, presentationBlocking: false), .ignore)
        XCTAssertEqual(PairingURLRouter.decision(sessionActive: true, presentationBlocking: true), .ignore)
    }
}

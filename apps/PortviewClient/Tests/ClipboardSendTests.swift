// SPDX-License-Identifier: Apache-2.0
import XCTest
import PortviewProtocol

@testable import PortviewClient

final class ClipboardSendTests: XCTestCase {
    private let marker = "PORTVIEW-G2-IOS-TO-MAC-PASTE-CONTROL"

    func testMarkerProducesOneExactClipboardUpdate() {
        let message = ClipboardSendPolicy.outboundMessage(text: marker, hostLocked: false)

        guard case .clipboardUpdate(let update) = message else {
            return XCTFail("expected one clipboard update")
        }
        XCTAssertEqual(update.text, marker)
    }

    func testEmptyTextProducesNoMessage() {
        XCTAssertNil(ClipboardSendPolicy.outboundMessage(text: "", hostLocked: false))
    }

    func testOneUTF8ByteOverCapProducesNoMessage() {
        let overCap = String(repeating: "a", count: Frame.maxClipboardBytes + 1)

        XCTAssertNil(ClipboardSendPolicy.outboundMessage(text: overCap, hostLocked: false))
    }

    func testTextExactlyAtCapProducesExactClipboardUpdate() {
        let atCap = String(repeating: "a", count: Frame.maxClipboardBytes)
        let message = ClipboardSendPolicy.outboundMessage(text: atCap, hostLocked: false)

        guard case .clipboardUpdate(let update) = message else {
            return XCTFail("expected one clipboard update at the cap")
        }
        XCTAssertEqual(update.text, atCap)
    }

    func testLockedHostProducesNoMessage() {
        XCTAssertNil(ClipboardSendPolicy.outboundMessage(text: marker, hostLocked: true))
    }
}

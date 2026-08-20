// SPDX-License-Identifier: Apache-2.0
import XCTest
import PortviewProtocol

@testable import PortviewClient

@MainActor
final class ClipboardSendTests: XCTestCase {
    private let marker = "PORTVIEW-G2-IOS-TO-MAC-PASTE-CONTROL"

    func testTextTakingClipboardSendEmitsExactMarkerOnce() {
        let viewModel = SessionViewModel()
        var messages: [AnyMessage] = []
        viewModel.outboundMessageSink = { messages.append($0) }

        viewModel.sendClipboardText(marker)

        XCTAssertEqual(messages.count, 1)
        guard case .clipboardUpdate(let update) = messages[0] else {
            return XCTFail("expected one clipboard update")
        }
        XCTAssertEqual(update.text, marker)
    }

    func testEmptyClipboardTextEmitsNothing() {
        let viewModel = SessionViewModel()
        var messages: [AnyMessage] = []
        viewModel.outboundMessageSink = { messages.append($0) }

        viewModel.sendClipboardText("")

        XCTAssertTrue(messages.isEmpty)
    }

    func testClipboardTextOneUTF8ByteOverCapEmitsNothing() {
        let viewModel = SessionViewModel()
        var messages: [AnyMessage] = []
        viewModel.outboundMessageSink = { messages.append($0) }
        let overCap = String(repeating: "a", count: Frame.maxClipboardBytes + 1)

        viewModel.sendClipboardText(overCap)

        XCTAssertTrue(messages.isEmpty)
    }
}

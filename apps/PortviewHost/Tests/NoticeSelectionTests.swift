// SPDX-License-Identifier: Apache-2.0
import XCTest

final class NoticeSelectionTests: XCTestCase {
    func testLongMessageIsKept() {
        let long = String(repeating: "x", count: 188)
        XCTAssertEqual(NoticeSelection.latest([long]).map(\.text), [long])
    }

    func testMultiLineMessageIsKeptAndFlattened() {
        XCTAssertEqual(NoticeSelection.latest(["line one\nline two"]).map(\.text), ["line one line two"])
    }

    func testKeepsLatestFewWithStableIds() {
        let notices = NoticeSelection.latest(["a", "b", "c", "d", "e"])
        XCTAssertEqual(notices.map(\.text), ["c", "d", "e"])
        XCTAssertEqual(notices.map(\.id), [2, 3, 4])
    }

    func testBlankMessagesAreSkipped() {
        XCTAssertEqual(NoticeSelection.latest(["  ", "\n", "real"]).map(\.text), ["real"])
    }
}

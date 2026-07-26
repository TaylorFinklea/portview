// SPDX-License-Identifier: Apache-2.0
import XCTest
import CoreGraphics
import PortviewClientCore

@testable import PortviewClient

@MainActor
final class KeyboardViewportTests: XCTestCase {
    private let windowBounds = CGRect(x: 0, y: 0, width: 390, height: 844)

    func testDockedKeyboardUsesReportedTopEdge() {
        let transition = KeyboardViewportTransition(
            keyboardIntersection: CGRect(x: 0, y: 506, width: 390, height: 338),
            duration: 0.25,
            curve: .easeInOut)

        XCTAssertEqual(transition.effectiveHeight(in: windowBounds), 506)
    }

    func testAccessoryBarChangeUsesReportedMinYRatherThanKeyboardHeight() {
        let transition = KeyboardViewportTransition(
            keyboardIntersection: CGRect(x: 0, y: 470, width: 390, height: 374),
            duration: 0.25,
            curve: .easeInOut)

        XCTAssertEqual(transition.effectiveHeight(in: windowBounds), 470)
    }

    func testFloatingKeyboardUsesRealIntersectionThenConservativeTopEdgePolicy() {
        let transition = KeyboardViewportTransition(
            keyboardIntersection: CGRect(x: 220, y: 380, width: 150, height: 210),
            duration: 0.25,
            curve: .easeInOut)

        XCTAssertEqual(transition.effectiveHeight(in: windowBounds), 380)
    }

    func testOffWindowAndHiddenFramesLeaveFullViewport() {
        let offWindow = KeyboardViewportTransition(
            keyboardIntersection: CGRect(x: 410, y: 300, width: 100, height: 200),
            duration: 0.25,
            curve: .easeInOut)
        let hidden = KeyboardViewportTransition.empty

        XCTAssertEqual(offWindow.effectiveHeight(in: windowBounds), 844)
        XCTAssertEqual(hidden.effectiveHeight(in: windowBounds), 844)
    }

    func testEffectiveHeightClampsToDrawableBounds() {
        let aboveWindow = KeyboardViewportTransition(
            keyboardIntersection: CGRect(x: 0, y: -100, width: 390, height: 300),
            duration: 0.25,
            curve: .easeInOut)

        XCTAssertEqual(aboveWindow.effectiveHeight(in: windowBounds), 0)
    }

    func testAnimationCurveParsingDistinguishesSystemKeyboardFallback() {
        XCTAssertEqual(KeyboardViewportTransition.Curve(rawValue: 0), .easeInOut)
        XCTAssertEqual(KeyboardViewportTransition.Curve(rawValue: 1), .easeIn)
        XCTAssertEqual(KeyboardViewportTransition.Curve(rawValue: 2), .easeOut)
        XCTAssertEqual(KeyboardViewportTransition.Curve(rawValue: 3), .linear)
        XCTAssertEqual(KeyboardViewportTransition.Curve(rawValue: 7), .systemKeyboard)
        XCTAssertEqual(KeyboardViewportTransition.Curve(rawValue: 99), .systemKeyboard)
    }

    func testZeroDurationIsImmediate() {
        let transition = KeyboardViewportTransition(
            keyboardIntersection: .zero,
            duration: 0,
            curve: .systemKeyboard)

        XCTAssertNil(transition.animation)
    }

    func testShortViewportRetainsOverviewAndMovesBottomCursorAtHighZoom() {
        let display = CGSize(width: 1920, height: 1080)
        let cursor = CGPoint(x: 0.5, y: 1)
        let viewport = CGSize(width: 390, height: 506)
        let overview = ZoomGeometry(view: viewport, displaySize: display, cursor: cursor, zoom: 1)
        let magnified = ZoomGeometry(view: viewport, displaySize: display, cursor: cursor, zoom: 5)

        XCTAssertEqual(overview.visibleWindow, CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertLessThan(magnified.visibleWindow.minY, 1)
        XCTAssertEqual(magnified.visibleWindow.maxY, 1, accuracy: 0.0001)
        XCTAssertTrue(ViewportCoverage.windowCovered(magnified.visibleWindow, by: magnified.cropRequest))
    }

    func testHardwareKeyboardAssistantBarIsSuppressed() {
        let view = KeyInputView()

        XCTAssertTrue(view.inputAssistantItem.leadingBarButtonGroups.isEmpty)
        XCTAssertTrue(view.inputAssistantItem.trailingBarButtonGroups.isEmpty)
    }
}

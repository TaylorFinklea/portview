// SPDX-License-Identifier: Apache-2.0
import XCTest

@testable import PortviewClient

/// First-run walkthrough persistence. Uses a unique UserDefaults suite, never the standard domain.
final class FirstRunStateTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "portview.tests.firstrun.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testFreshStateHasNotCompletedWalkthrough() {
        let store = FirstRunStateStore(defaults: defaults)
        XCTAssertFalse(store.hasCompletedWalkthrough)
    }

    func testCompletionPersistsAcrossANewStore() {
        FirstRunStateStore(defaults: defaults).complete()
        XCTAssertTrue(FirstRunStateStore(defaults: defaults).hasCompletedWalkthrough)
    }

    func testRepeatCompletionIsHarmless() {
        let store = FirstRunStateStore(defaults: defaults)
        store.complete()
        store.complete()
        XCTAssertTrue(store.hasCompletedWalkthrough)
        XCTAssertTrue(FirstRunStateStore(defaults: defaults).hasCompletedWalkthrough)
    }

    func testShowAgainIsPresentationOnlyAndLeavesCompletionAndOtherDefaultsAlone() {
        defaults.set("kept", forKey: "other.setting")
        let store = FirstRunStateStore(defaults: defaults)
        store.complete()

        // Re-opening from Settings is a presentation action: it only flips presentation state.
        var presentation = WalkthroughPresentation(store: store)
        XCTAssertFalse(presentation.isPresented)
        presentation.showAgain()
        XCTAssertTrue(presentation.isPresented)
        XCTAssertTrue(store.hasCompletedWalkthrough)
        XCTAssertEqual(defaults.string(forKey: "other.setting"), "kept")

        presentation.finish()
        XCTAssertFalse(presentation.isPresented)
        XCTAssertTrue(store.hasCompletedWalkthrough)
    }

    func testFreshPresentationShowsAndFinishingCompletes() {
        let store = FirstRunStateStore(defaults: defaults)
        var presentation = WalkthroughPresentation(store: store)
        XCTAssertTrue(presentation.isPresented)
        presentation.finish()
        XCTAssertFalse(presentation.isPresented)
        XCTAssertTrue(store.hasCompletedWalkthrough)
    }

    func testThreePagesAndCopyStaysHonestAboutForegroundAndRewake() {
        let pages = WalkthroughPage.all
        XCTAssertEqual(pages.count, 3)
        XCTAssertTrue(pages[0].body.contains("only while the app is open"))
        XCTAssertTrue(pages[2].body.contains("best-effort"))
        XCTAssertTrue(pages[2].body.contains("off until you enable them on the Mac"))
    }
}

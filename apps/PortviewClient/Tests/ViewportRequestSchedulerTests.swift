import CoreGraphics
import XCTest

@testable import PortviewClient

@MainActor
final class ViewportRequestSchedulerTests: XCTestCase {
    func testDebouncesToLatestViewport() async throws {
        let first = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        let latest = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        var sent: [CGRect] = []
        let scheduler = ViewportRequestScheduler(delay: .milliseconds(20)) { sent.append($0) }

        scheduler.request(first)
        scheduler.request(latest)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(sent, [latest])
    }

    func testResetCancelsPendingViewport() async throws {
        var sent: [CGRect] = []
        let scheduler = ViewportRequestScheduler(delay: .milliseconds(20)) { sent.append($0) }

        scheduler.request(CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))
        scheduler.reset()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(sent.isEmpty)
    }

    func testDoesNotSendNearDuplicateViewport() async throws {
        var sent: [CGRect] = []
        let scheduler = ViewportRequestScheduler(delay: .milliseconds(20)) { sent.append($0) }

        scheduler.request(CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))
        try await Task.sleep(for: .milliseconds(50))
        scheduler.request(CGRect(x: 0.2005, y: 0.2005, width: 0.6005, height: 0.6005))
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(sent, [CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)])
    }
}

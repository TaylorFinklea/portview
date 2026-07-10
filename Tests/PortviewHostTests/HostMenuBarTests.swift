// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import PortviewHostCore

/// The menu-bar glyph reflects host state at a glance: failed > connected > running > idle.
@Suite struct HostMenuBarTests {
    @Test func idleShowsDisplay() {
        #expect(HostMenuBar.symbol(isFailed: false, isRunning: false, connectedCount: 0) == "display")
    }

    @Test func runningAdvertisingShowsAntenna() {
        #expect(HostMenuBar.symbol(isFailed: false, isRunning: true, connectedCount: 0) == "antenna.radiowaves.left.and.right")
    }

    @Test func connectedShowsIphoneRadiowaves() {
        #expect(HostMenuBar.symbol(isFailed: false, isRunning: true, connectedCount: 1) == "iphone.radiowaves.left.and.right")
    }

    @Test func connectedTakesPrecedenceOverRunning() {
        #expect(HostMenuBar.symbol(isFailed: false, isRunning: true, connectedCount: 2) == "iphone.radiowaves.left.and.right")
    }

    @Test func failedTakesPrecedenceOverEverything() {
        #expect(HostMenuBar.symbol(isFailed: true, isRunning: true, connectedCount: 3) == "exclamationmark.triangle.fill")
    }
}

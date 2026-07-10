// SPDX-License-Identifier: Apache-2.0
import Testing
import PortviewProtocol
@testable import PortviewHostCore

/// Runtime display refresh: the host periodically re-reads the display list and re-advertises it to
/// connected clients when the *set* of displays changes (a monitor connected, woke, was removed, or
/// changed resolution) — so the client's display switcher reappears without a host relaunch.
/// `displaysChanged` is the pure decision behind the broadcast; it must be order-independent (the OS
/// can reorder the list) but sensitive to identity, count, and dimensions.
@Suite struct DisplayRefreshTests {
    private let builtin = DisplayInfo(id: 1, name: "Display 1", width: 3456, height: 2234, scaleX100: 200)
    private let external = DisplayInfo(id: 2, name: "Display 2", width: 3440, height: 1440, scaleX100: 100)

    @Test func sameSetIsNotAChange() {
        #expect(!HostRunner.displaysChanged(from: [builtin, external], to: [builtin, external]))
    }

    @Test func reorderedSameSetIsNotAChange() {
        #expect(!HostRunner.displaysChanged(from: [builtin, external], to: [external, builtin]))
    }

    @Test func addedDisplayIsAChange() {
        #expect(HostRunner.displaysChanged(from: [builtin], to: [builtin, external]))
    }

    @Test func removedDisplayIsAChange() {
        #expect(HostRunner.displaysChanged(from: [builtin, external], to: [builtin]))
    }

    @Test func resolutionChangeIsAChange() {
        let resized = DisplayInfo(id: 2, name: "Display 2", width: 1920, height: 1080, scaleX100: 100)
        #expect(HostRunner.displaysChanged(from: [builtin, external], to: [builtin, resized]))
    }
}

// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import PortviewHostCore

@Suite struct HostRuntimePreferencesTests {
    @Test func explicitPortWinsOverLastBound() {
        #expect(HostRuntimePreferences(preferredPort: 7443, preferredDisplayID: nil)
            .listenerPort(lastBoundPort: 9000) == 7443)
    }

    @Test func lastBoundPortUsedWhenNoPreference() {
        #expect(HostRuntimePreferences(preferredPort: nil, preferredDisplayID: nil)
            .listenerPort(lastBoundPort: 9000) == 9000)
    }

    @Test func candidatesAreOrderedAndDeduplicated() {
        let p = HostRuntimePreferences(preferredPort: 7443, preferredDisplayID: nil)
        #expect(p.listenerPortCandidates(lastBoundPort: 9000) == [7443, 9000])
        #expect(p.listenerPortCandidates(lastBoundPort: 7443) == [7443])
        #expect(p.listenerPortCandidates(lastBoundPort: nil) == [7443])
        #expect(HostRuntimePreferences.default.listenerPortCandidates(lastBoundPort: nil).isEmpty)
    }

    @Test func preferredDisplayChosenWhenAvailable() {
        #expect(HostRuntimePreferences(preferredPort: nil, preferredDisplayID: 42)
            .initialDisplayID(available: [7, 42]) == 42)
    }

    @Test func missingPreferredDisplayFallsBackToFirst() {
        #expect(HostRuntimePreferences(preferredPort: nil, preferredDisplayID: 99)
            .initialDisplayID(available: [7, 42]) == 7)
        #expect(HostRuntimePreferences.default.initialDisplayID(available: []) == nil)
    }

    @Test func orderingMovesPreferredDisplayToFront() {
        let p = HostRuntimePreferences(preferredPort: nil, preferredDisplayID: 42)
        #expect(p.orderedDisplays([7, 42, 9], id: { $0 }) == [42, 7, 9])
    }

    @Test func orderingKeepsOriginalWhenPreferredAbsentOrUnset() {
        let absent = HostRuntimePreferences(preferredPort: nil, preferredDisplayID: 99)
        #expect(absent.orderedDisplays([7, 42, 9], id: { $0 }) == [7, 42, 9])
        #expect(HostRuntimePreferences.default.orderedDisplays([7, 42, 9], id: { $0 }) == [7, 42, 9])
    }
}

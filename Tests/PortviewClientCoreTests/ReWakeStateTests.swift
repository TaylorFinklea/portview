// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

import PortviewClientCore

/// `ReWakeState` persistence codec: JSON round-trip of BOTH per-host maps + the change token + the
/// one-time flags, tolerant decode of missing/corrupt data, and `markActed` stamping both maps
/// together (the `ReWakeDecision.evaluate` caller contract).
@Suite struct ReWakeStateTests {
    @Test func roundTripsBothMapsChangeTokenAndFlags() throws {
        // Sub-second Date to prove the codec preserves precision, not just whole seconds.
        let actedA = Date(timeIntervalSince1970: 1_751_900_000.125)
        let actedB = Date(timeIntervalSince1970: 1_751_900_030.5)
        let original = ReWakeState(
            lastHandledEpochs: ["aaaa1111": 1_751_900_000_000_000, "bbbb2222": 42],
            lastActedAt: ["aaaa1111": actedA, "bbbb2222": actedB],
            changeTokenData: Data([0x01, 0x02, 0xFF]),
            didRequestNotificationAuth: true,
            didShowDeniedHint: true)

        let data = try #require(original.encoded())
        let decoded = ReWakeState.decoded(from: data)

        #expect(decoded == original)
        #expect(decoded.lastHandledEpochs["bbbb2222"] == 42)
        #expect(decoded.lastActedAt["aaaa1111"] == actedA)
        #expect(decoded.changeTokenData == Data([0x01, 0x02, 0xFF]))
    }

    @Test func decodingNilDataYieldsEmptyState() {
        let state = ReWakeState.decoded(from: nil)
        #expect(state == ReWakeState())
        #expect(state.lastHandledEpochs.isEmpty)
        #expect(state.lastActedAt.isEmpty)
        #expect(state.changeTokenData == nil)
        #expect(!state.didRequestNotificationAuth)
        #expect(!state.didShowDeniedHint)
    }

    @Test func decodingCorruptDataYieldsEmptyState() {
        let state = ReWakeState.decoded(from: Data("not json".utf8))
        #expect(state == ReWakeState())
    }

    @Test func nilChangeTokenRoundTripsAsNil() throws {
        let original = ReWakeState(lastHandledEpochs: ["aaaa1111": 7], changeTokenData: nil)
        let decoded = ReWakeState.decoded(from: try #require(original.encoded()))
        #expect(decoded.changeTokenData == nil)
        #expect(decoded == original)
    }

    @Test func markActedStampsBothMapsForTheBeaconsHostOnly() {
        let now = Date()
        var state = ReWakeState(
            lastHandledEpochs: ["bbbb2222": 5],
            lastActedAt: ["bbbb2222": now.addingTimeInterval(-100)])
        let beacon = HostBeaconRecord(recordName: "aaaa1111", hostName: "Mac", port: 4433, epoch: 99, wantsReconnect: 1)

        state.markActed(on: beacon, at: now)

        #expect(state.lastHandledEpochs == ["aaaa1111": 99, "bbbb2222": 5])
        #expect(state.lastActedAt["aaaa1111"] == now)
        #expect(state.lastActedAt["bbbb2222"] == now.addingTimeInterval(-100))
    }
}

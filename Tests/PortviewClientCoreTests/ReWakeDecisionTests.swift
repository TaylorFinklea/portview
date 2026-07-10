// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

import PortviewClientCore

/// `ReWakeDecision.evaluate` policy (spec §3): unknown host → ignore; per-host epoch dedupe/replay
/// guard that a nudge (`wantsReconnect = 1`) always bypasses; a per-host wall-clock rate limit fed
/// by the CLIENT's own `lastActedAt` map (never derived from host epochs — those may be counters);
/// and the "one host's state must never suppress another host's" isolation the per-host maps exist for.
@Suite struct ReWakeDecisionTests {
    private let pinA = "aaaa1111"
    private let pinB = "bbbb2222"

    private func epochMicros(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000_000)
    }

    // MARK: unknown host

    @Test func unknownHostIsIgnored() {
        let now = Date()
        let beacon = HostBeaconRecord(recordName: pinA, hostName: "Mac", port: 4433, epoch: epochMicros(now), wantsReconnect: 1)
        let action = ReWakeDecision.evaluate(
            beacon: beacon, savedHosts: [], lastHandledEpochs: [:], lastActedAt: [:], now: now
        )
        #expect(action == .ignore)
    }

    // MARK: epoch dedupe/replay (routine beacons)

    @Test func routineBeaconWithEpochAtOrBelowLastHandledIsIgnored() {
        let now = Date()
        let saved = [ReWakeDecision.SavedHost(pinHex: pinA, host: "10.0.0.5")]
        let lastHandled: Int64 = epochMicros(now.addingTimeInterval(-100))
        // Equal epoch (exact replay) and a strictly older epoch both must be ignored, regardless of
        // rate-limit state (no lastActedAt entry at all).
        for epoch in [lastHandled, lastHandled - 1] {
            let beacon = HostBeaconRecord(recordName: pinA, hostName: "Mac", port: 4433, epoch: epoch, wantsReconnect: 0)
            let action = ReWakeDecision.evaluate(
                beacon: beacon, savedHosts: saved, lastHandledEpochs: [pinA: lastHandled], lastActedAt: [:], now: now
            )
            #expect(action == .ignore)
        }
    }

    @Test func routineBeaconWithFreshEpochIsActedOn() {
        let now = Date()
        let saved = [ReWakeDecision.SavedHost(pinHex: pinA, host: "10.0.0.5")]
        // Previous act was long enough ago to clear the rate limit too.
        let actedAt = now.addingTimeInterval(-ReWakeDecision.minActInterval - 10)
        let lastHandled = epochMicros(actedAt)
        let beacon = HostBeaconRecord(recordName: pinA, hostName: "Mac", port: 4433, epoch: epochMicros(now), wantsReconnect: 0)
        let action = ReWakeDecision.evaluate(
            beacon: beacon, savedHosts: saved, lastHandledEpochs: [pinA: lastHandled], lastActedAt: [pinA: actedAt], now: now
        )
        #expect(action == .reachabilityProbe(endpoint: .init(host: "10.0.0.5", port: 4433), pin: pinA))
    }

    // MARK: required test (a) — host rebooted, epoch regressed, nudge bypasses the dedupe

    /// A beacon whose (wall-clock) epoch is BELOW the stored per-host value — e.g. a persisted-counter
    /// host that lost its counter, or a clock regression across a reboot — is still handled as long as
    /// `wantsReconnect = 1`: the dedupe/replay guard must never eat an explicit nudge.
    @Test func rebootedHostEpochRegressionStillHandledWhenNudged() {
        let now = Date()
        let saved = [ReWakeDecision.SavedHost(pinHex: pinA, host: "10.0.0.5")]
        // "Before reboot" the host had run up a much larger epoch than its "after reboot" beacon
        // reports; enough real time passed (a reboot takes time) that the rate limit has also cleared.
        let beforeReboot = now.addingTimeInterval(-ReWakeDecision.minActInterval - 60)
        let lastHandled = epochMicros(beforeReboot) + 500_000 // +0.5s, still "before reboot"
        let regressedEpoch = epochMicros(beforeReboot) // numerically smaller than lastHandled
        let beacon = HostBeaconRecord(recordName: pinA, hostName: "Mac", port: 4433, epoch: regressedEpoch, wantsReconnect: 1)

        let action = ReWakeDecision.evaluate(
            beacon: beacon, savedHosts: saved, lastHandledEpochs: [pinA: lastHandled], lastActedAt: [pinA: beforeReboot], now: now
        )

        #expect(action == .reachabilityProbe(endpoint: .init(host: "10.0.0.5", port: 4433), pin: pinA))
    }

    /// The same regressed epoch WITHOUT the nudge flag is a routine replay and is correctly ignored —
    /// proves the bypass above is specific to `wantsReconnect`, not a blanket epoch-check skip.
    @Test func rebootedHostEpochRegressionIgnoredWhenRoutine() {
        let now = Date()
        let saved = [ReWakeDecision.SavedHost(pinHex: pinA, host: "10.0.0.5")]
        let beforeReboot = now.addingTimeInterval(-ReWakeDecision.minActInterval - 60)
        let lastHandled = epochMicros(beforeReboot) + 500_000
        let regressedEpoch = epochMicros(beforeReboot)
        let beacon = HostBeaconRecord(recordName: pinA, hostName: "Mac", port: 4433, epoch: regressedEpoch, wantsReconnect: 0)

        let action = ReWakeDecision.evaluate(
            beacon: beacon, savedHosts: saved, lastHandledEpochs: [pinA: lastHandled], lastActedAt: [pinA: beforeReboot], now: now
        )

        #expect(action == .ignore)
    }

    // MARK: required test (b) — one host's state never suppresses another

    @Test func oneHostsLargeEpochNeverSuppressesADifferentHost() {
        let now = Date()
        let saved = [
            ReWakeDecision.SavedHost(pinHex: pinA, host: "10.0.0.5"),
            ReWakeDecision.SavedHost(pinHex: pinB, host: "10.0.0.9"),
        ]
        // Host A has a huge last-handled epoch (long-running desktop) AND was acted on this instant;
        // host B is fresh and its own epoch numerically reads well below host A's — neither A's epoch
        // nor A's rate-limit window may matter, both maps are keyed per host.
        let hostALastHandled = epochMicros(now) + 999_999_999_999
        let beaconForB = HostBeaconRecord(recordName: pinB, hostName: "Laptop", port: 4433, epoch: epochMicros(now), wantsReconnect: 0)

        let action = ReWakeDecision.evaluate(
            beacon: beaconForB, savedHosts: saved, lastHandledEpochs: [pinA: hostALastHandled], lastActedAt: [pinA: now], now: now
        )

        #expect(action == .reachabilityProbe(endpoint: .init(host: "10.0.0.9", port: 4433), pin: pinB))
    }

    // MARK: required test — per-host rate limit (fed by lastActedAt, never by epochs)

    @Test func rateLimitIgnoresAnotherActionTooSoonAfterTheLast() {
        let now = Date()
        let saved = [ReWakeDecision.SavedHost(pinHex: pinA, host: "10.0.0.5")]
        let beacon = HostBeaconRecord(recordName: pinA, hostName: "Mac", port: 4433, epoch: epochMicros(now), wantsReconnect: 1)

        let action = ReWakeDecision.evaluate(
            beacon: beacon, savedHosts: saved, lastHandledEpochs: [pinA: epochMicros(now.addingTimeInterval(-100))],
            lastActedAt: [pinA: now.addingTimeInterval(-ReWakeDecision.minActInterval / 2)], now: now
        )

        #expect(action == .ignore)
    }

    @Test func actsAgainOnceTheRateLimitWindowHasElapsed() {
        let now = Date()
        let saved = [ReWakeDecision.SavedHost(pinHex: pinA, host: "10.0.0.5")]
        let beacon = HostBeaconRecord(recordName: pinA, hostName: "Mac", port: 4433, epoch: epochMicros(now), wantsReconnect: 1)

        let action = ReWakeDecision.evaluate(
            beacon: beacon, savedHosts: saved, lastHandledEpochs: [pinA: epochMicros(now.addingTimeInterval(-100))],
            lastActedAt: [pinA: now.addingTimeInterval(-ReWakeDecision.minActInterval - 1)], now: now
        )

        #expect(action == .reachabilityProbe(endpoint: .init(host: "10.0.0.5", port: 4433), pin: pinA))
    }

    /// Exactly `minActInterval` elapsed acts again — pins the strict-< semantics of the window.
    @Test func actsAgainAtExactlyTheRateLimitBoundary() {
        let now = Date()
        let saved = [ReWakeDecision.SavedHost(pinHex: pinA, host: "10.0.0.5")]
        let beacon = HostBeaconRecord(recordName: pinA, hostName: "Mac", port: 4433, epoch: epochMicros(now), wantsReconnect: 1)

        let action = ReWakeDecision.evaluate(
            beacon: beacon, savedHosts: saved, lastHandledEpochs: [:],
            lastActedAt: [pinA: now.addingTimeInterval(-ReWakeDecision.minActInterval)], now: now
        )

        #expect(action == .reachabilityProbe(endpoint: .init(host: "10.0.0.5", port: 4433), pin: pinA))
    }

    /// Spec §1 permits counter-style epochs (1, 2, 3, …). The rate limit must still engage for them —
    /// it runs on the client's own `lastActedAt` clock, never on an epoch reinterpreted as a date
    /// (a small counter read as micros-since-1970 would make the window read ~56 years and never fire).
    @Test func counterStyleEpochsStillRateLimit() {
        let now = Date()
        let saved = [ReWakeDecision.SavedHost(pinHex: pinA, host: "10.0.0.5")]
        let beacon = HostBeaconRecord(recordName: pinA, hostName: "Mac", port: 4433, epoch: 7, wantsReconnect: 1)

        let tooSoon = ReWakeDecision.evaluate(
            beacon: beacon, savedHosts: saved, lastHandledEpochs: [pinA: 6],
            lastActedAt: [pinA: now.addingTimeInterval(-5)], now: now
        )
        #expect(tooSoon == .ignore)

        let afterWindow = ReWakeDecision.evaluate(
            beacon: beacon, savedHosts: saved, lastHandledEpochs: [pinA: 6],
            lastActedAt: [pinA: now.addingTimeInterval(-ReWakeDecision.minActInterval - 1)], now: now
        )
        #expect(afterWindow == .reachabilityProbe(endpoint: .init(host: "10.0.0.5", port: 4433), pin: pinA))
    }

    @Test func firstEverBeaconForAKnownHostHasNothingToRateLimitAgainst() {
        let now = Date()
        let saved = [ReWakeDecision.SavedHost(pinHex: pinA, host: "10.0.0.5")]
        let beacon = HostBeaconRecord(recordName: pinA, hostName: "Mac", port: 4433, epoch: epochMicros(now), wantsReconnect: 0)

        let action = ReWakeDecision.evaluate(
            beacon: beacon, savedHosts: saved, lastHandledEpochs: [:], lastActedAt: [:], now: now
        )

        #expect(action == .reachabilityProbe(endpoint: .init(host: "10.0.0.5", port: 4433), pin: pinA))
    }
}

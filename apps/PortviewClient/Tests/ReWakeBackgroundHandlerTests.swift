// SPDX-License-Identifier: Apache-2.0
import PortviewClientCore
import UIKit
import XCTest

@testable import PortviewClient

/// `ReWakeBackgroundHandler.run()` — one silent push orchestrated with every effect injected:
/// an outcome is returned on EVERY fetch/probe/routing path (the structural guarantee that lets
/// the app delegate call the push completion handler unconditionally), foreground-vs-background
/// routing, and persistence of BOTH per-host maps + the change token.
@MainActor
final class ReWakeBackgroundHandlerTests: XCTestCase {
    private let pin = String(repeating: "a", count: 64)

    /// Effect recorder the injected closures write into.
    private final class Recorder {
        var savedStates: [ReWakeState] = []
        var postedBeacons: [HostBeaconRecord] = []
        var kickedPinHexes: [String] = []
        var probedBeacons: [HostBeaconRecord] = []
    }

    private func beacon(epoch: Int64 = 1_000, wantsReconnect: Int64 = 0) -> HostBeaconRecord {
        HostBeaconRecord(recordName: pin, hostName: "Roshar", port: 4433, epoch: epoch, wantsReconnect: wantsReconnect)
    }

    private func makeHandler(
        recorder: Recorder,
        initialState: ReWakeState = ReWakeState(),
        fetch: ReWakeFetchOutcome,
        probeSucceeds: Bool = true,
        isForeground: Bool = false,
        hasLiveSession: Bool = false,
        savedHosts: [ReWakeDecision.SavedHost]? = nil
    ) -> ReWakeBackgroundHandler {
        ReWakeBackgroundHandler(
            loadState: { initialState },
            saveState: { recorder.savedStates.append($0) },
            savedHosts: { savedHosts ?? [ReWakeDecision.SavedHost(pinHex: self.pin, host: "10.0.0.5")] },
            fetchChanges: { _ in fetch },
            probe: { beacon, _, _ in
                recorder.probedBeacons.append(beacon)
                return probeSucceeds
            },
            isForeground: { isForeground },
            hasLiveSession: { hasLiveSession },
            postNotification: { recorder.postedBeacons.append($0) },
            kickReconnect: { recorder.kickedPinHexes.append($0) })
    }

    // MARK: - Background push → local notification, state persisted

    func testBackgroundProbeSuccessPostsNotificationAndPersistsBothMapsAndToken() async {
        let recorder = Recorder()
        let token = Data([0xAB, 0xCD])
        let handler = makeHandler(
            recorder: recorder,
            fetch: ReWakeFetchOutcome(status: .ok, beacons: [beacon(epoch: 77)], changeTokenData: token),
            isForeground: false)

        let outcome = await handler.run()

        XCTAssertEqual(outcome, .newData)
        XCTAssertEqual(recorder.postedBeacons.map(\.recordName), [pin])
        XCTAssertTrue(recorder.kickedPinHexes.isEmpty)
        // Persistence: the final saved state carries BOTH per-host maps AND the advanced token.
        let final = recorder.savedStates.last
        XCTAssertEqual(final?.lastHandledEpochs[pin], 77)
        XCTAssertNotNil(final?.lastActedAt[pin])
        XCTAssertEqual(final?.changeTokenData, token)
    }

    // MARK: - Foreground routing

    func testForegroundProbeSuccessKicksInAppReconnectInsteadOfNotifying() async {
        let recorder = Recorder()
        let handler = makeHandler(
            recorder: recorder,
            fetch: ReWakeFetchOutcome(status: .ok, beacons: [beacon()]),
            isForeground: true)

        let outcome = await handler.run()

        XCTAssertEqual(outcome, .newData)
        XCTAssertEqual(recorder.kickedPinHexes, [pin])
        XCTAssertTrue(recorder.postedBeacons.isEmpty)
    }

    func testForegroundWithLiveSessionStaysCompletelySilent() async {
        let recorder = Recorder()
        let handler = makeHandler(
            recorder: recorder,
            fetch: ReWakeFetchOutcome(status: .ok, beacons: [beacon()]),
            isForeground: true,
            hasLiveSession: true)

        let outcome = await handler.run()

        XCTAssertEqual(outcome, .newData)
        XCTAssertTrue(recorder.kickedPinHexes.isEmpty)
        XCTAssertTrue(recorder.postedBeacons.isEmpty)
    }

    // MARK: - Failed probe: silent, but the act is still stamped (no re-probe burst)

    func testFailedProbeStaysSilentYetStampsBothMaps() async {
        let recorder = Recorder()
        let handler = makeHandler(
            recorder: recorder,
            fetch: ReWakeFetchOutcome(status: .ok, beacons: [beacon(epoch: 55)]),
            probeSucceeds: false)

        let outcome = await handler.run()

        XCTAssertEqual(outcome, .newData)
        XCTAssertTrue(recorder.postedBeacons.isEmpty)
        XCTAssertTrue(recorder.kickedPinHexes.isEmpty)
        XCTAssertEqual(recorder.savedStates.last?.lastHandledEpochs[pin], 55)
        XCTAssertNotNil(recorder.savedStates.last?.lastActedAt[pin])
    }

    // MARK: - Decision plumbing: unknown host / replayed epoch never probe

    func testUnknownHostIsIgnoredButTokenStillAdvances() async {
        let recorder = Recorder()
        let token = Data([0x01])
        let handler = makeHandler(
            recorder: recorder,
            fetch: ReWakeFetchOutcome(status: .ok, beacons: [beacon()], changeTokenData: token),
            savedHosts: [])

        let outcome = await handler.run()

        XCTAssertEqual(outcome, .newData)
        XCTAssertTrue(recorder.probedBeacons.isEmpty)
        XCTAssertEqual(recorder.savedStates.last?.changeTokenData, token)
        XCTAssertEqual(recorder.savedStates.last?.lastHandledEpochs, [:])
    }

    func testReplayedEpochIsDedupedWithoutProbing() async {
        let recorder = Recorder()
        let handler = makeHandler(
            recorder: recorder,
            initialState: ReWakeState(lastHandledEpochs: [pin: 1_000]),
            fetch: ReWakeFetchOutcome(status: .ok, beacons: [beacon(epoch: 1_000)]))

        let outcome = await handler.run()

        XCTAssertEqual(outcome, .newData)
        XCTAssertTrue(recorder.probedBeacons.isEmpty)
        XCTAssertTrue(recorder.postedBeacons.isEmpty)
    }

    // MARK: - Fetch statuses: an outcome is returned on EVERY path (the completion-handler pin)

    func testZoneNotReadyReturnsNoDataAndLeavesStateUntouched() async {
        let recorder = Recorder()
        let handler = makeHandler(recorder: recorder, fetch: ReWakeFetchOutcome(status: .zoneNotReady))

        let outcome = await handler.run()

        XCTAssertEqual(outcome, .noData)
        XCTAssertTrue(recorder.savedStates.isEmpty)
    }

    func testExpiredTokenIsClearedAndReturnsFailed() async {
        let recorder = Recorder()
        let handler = makeHandler(
            recorder: recorder,
            initialState: ReWakeState(changeTokenData: Data([0x99])),
            fetch: ReWakeFetchOutcome(status: .tokenExpired))

        let outcome = await handler.run()

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(recorder.savedStates.count, 1)
        XCTAssertNil(recorder.savedStates.last?.changeTokenData)
    }

    func testFetchFailureReturnsFailedWithoutAdvancingTheToken() async {
        let recorder = Recorder()
        let handler = makeHandler(
            recorder: recorder,
            initialState: ReWakeState(changeTokenData: Data([0x42])),
            fetch: ReWakeFetchOutcome(status: .failure))

        let outcome = await handler.run()

        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(recorder.savedStates.isEmpty) // token untouched — the next push retries it
    }

    /// Exhaustive sweep: every fetch status × probe outcome × app state produces SOME outcome —
    /// the structural guarantee the app delegate relies on to call the silent-push completion
    /// handler on every path.
    func testEveryPathProducesAnOutcome() async {
        for status in [ReWakeFetchOutcome.Status.ok, .zoneNotReady, .tokenExpired, .failure] {
            for probeSucceeds in [true, false] {
                for isForeground in [true, false] {
                    let recorder = Recorder()
                    let handler = makeHandler(
                        recorder: recorder,
                        fetch: ReWakeFetchOutcome(status: status, beacons: [beacon()]),
                        probeSucceeds: probeSucceeds,
                        isForeground: isForeground)
                    let outcome = await handler.run()
                    let mapped: UIBackgroundFetchResult = outcome.fetchResult
                    XCTAssertTrue([.newData, .noData, .failed].contains(mapped))
                }
            }
        }
    }

    // MARK: - Deadline guard (the budget half of the completion-handler guarantee)

    func testDeadlineBoundsAHungOperation() async {
        let start = ContinuousClock.now
        let result = await ReWakeDeadline.run(seconds: 0.1) { () -> Bool? in
            try? await Task.sleep(for: .seconds(30))
            return true
        }
        XCTAssertNil(result)
        XCTAssertLessThan(start.duration(to: .now), .seconds(5))
    }

    func testDeadlinePassesThroughAPromptResult() async {
        let result = await ReWakeDeadline.run(seconds: 5) { true }
        XCTAssertEqual(result, true)
    }
}

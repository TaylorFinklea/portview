// SPDX-License-Identifier: Apache-2.0
import PortviewClientCore
import PortviewProtocol
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

    /// Effect recorder the injected closures write into. `currentState` is a faithful store
    /// double — loads reflect earlier saves, exactly like the UserDefaults-backed production
    /// store — which the handler's narrow read-modify-write persists rely on.
    private final class Recorder {
        var currentState = ReWakeState()
        var savedStates: [ReWakeState] = []
        var postedBeacons: [HostBeaconRecord] = []
        var kickedPinHexes: [String] = []
        var probedBeacons: [HostBeaconRecord] = []
        var fetchedTokens: [Data?] = []
    }

    private func beacon(epoch: Int64 = 1_000, wantsReconnect: Int64 = 0) -> HostBeaconRecord {
        HostBeaconRecord(recordName: pin, hostName: "Roshar", port: 4433, epoch: epoch, wantsReconnect: wantsReconnect)
    }

    private func makeHandler(
        recorder: Recorder,
        initialState: ReWakeState = ReWakeState(),
        fetch: ReWakeFetchOutcome,
        fetchAfterExpiry: ReWakeFetchOutcome? = nil,
        probeSucceeds: Bool = true,
        isForeground: Bool = false,
        hasLiveSession: Bool = false,
        liveSessionPinHex: String? = nil,
        savedHosts: [ReWakeDecision.SavedHost]? = nil,
        onProbe: (() -> Void)? = nil
    ) -> ReWakeBackgroundHandler {
        recorder.currentState = initialState
        return ReWakeBackgroundHandler(
            loadState: { recorder.currentState },
            saveState: {
                recorder.currentState = $0
                recorder.savedStates.append($0)
            },
            savedHosts: { savedHosts ?? [ReWakeDecision.SavedHost(pinHex: self.pin, host: "10.0.0.5")] },
            fetchChanges: { token in
                recorder.fetchedTokens.append(token)
                if let fetchAfterExpiry, token == nil { return fetchAfterExpiry }
                return fetch
            },
            probe: { beacon, _, _ in
                recorder.probedBeacons.append(beacon)
                onProbe?()
                return probeSucceeds
            },
            isForeground: { isForeground },
            hasLiveSession: { hasLiveSession },
            liveSessionPinHex: { liveSessionPinHex },
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

    func testExpiredTokenRefetchesFromScratchInTheSameRun() async {
        // The system never redelivers a push: returning .failed on tokenExpired would drop the
        // very wake that triggered it. The handler must clear the token and refetch immediately.
        let recorder = Recorder()
        let token = Data([0x07])
        let handler = makeHandler(
            recorder: recorder,
            initialState: ReWakeState(changeTokenData: Data([0x99])),
            fetch: ReWakeFetchOutcome(status: .tokenExpired),
            fetchAfterExpiry: ReWakeFetchOutcome(status: .ok, beacons: [beacon(epoch: 88)], changeTokenData: token))

        let outcome = await handler.run()

        XCTAssertEqual(outcome, .newData)
        XCTAssertEqual(recorder.fetchedTokens.count, 2)
        XCTAssertEqual(recorder.fetchedTokens[0], Data([0x99]))
        XCTAssertNil(recorder.fetchedTokens[1]) // from scratch
        XCTAssertEqual(recorder.postedBeacons.map(\.recordName), [pin])
        XCTAssertEqual(recorder.currentState.changeTokenData, token)
        XCTAssertEqual(recorder.currentState.lastHandledEpochs[pin], 88)
    }

    func testTokenPersistsOnlyAfterTheWholeBatchWasProcessed() async {
        // A kill mid-batch must refetch the same changes (dedupe skips the acted-on beacons); a
        // token persisted with the FIRST beacon's stamp would permanently drop the later hosts'
        // wakes. So no saved state may carry the new token before the last beacon was handled.
        let otherPin = String(repeating: "b", count: 64)
        let recorder = Recorder()
        let token = Data([0xEE])
        let second = HostBeaconRecord(recordName: otherPin, hostName: "Sel", port: 4434, epoch: 5, wantsReconnect: 0)
        let handler = makeHandler(
            recorder: recorder,
            fetch: ReWakeFetchOutcome(status: .ok, beacons: [beacon(epoch: 77), second], changeTokenData: token),
            savedHosts: [
                ReWakeDecision.SavedHost(pinHex: pin, host: "10.0.0.5"),
                ReWakeDecision.SavedHost(pinHex: otherPin, host: "10.0.0.6"),
            ])

        let outcome = await handler.run()

        XCTAssertEqual(outcome, .newData)
        XCTAssertEqual(recorder.probedBeacons.count, 2)
        for state in recorder.savedStates where state.changeTokenData == token {
            // Any state carrying the advanced token must already carry BOTH hosts' act stamps.
            XCTAssertEqual(state.lastHandledEpochs[pin], 77)
            XCTAssertEqual(state.lastHandledEpochs[otherPin], 5)
        }
        XCTAssertEqual(recorder.currentState.changeTokenData, token)
    }

    func testMidRunExternalStateWriteSurvivesTheFinalPersist() async {
        // A foreground refresh can burn a one-time flag while a push handler is mid-probe. The
        // handler's saves are narrow read-modify-writes, so the external write must survive its
        // final (token) persist instead of being clobbered by a stale whole-struct copy.
        let recorder = Recorder()
        let handler = makeHandler(
            recorder: recorder,
            fetch: ReWakeFetchOutcome(status: .ok, beacons: [beacon()], changeTokenData: Data([0x11])),
            onProbe: {
                var external = recorder.currentState
                external.didShowDeniedHint = true
                recorder.currentState = external
            })

        _ = await handler.run()

        XCTAssertTrue(recorder.currentState.didShowDeniedHint)
        XCTAssertEqual(recorder.currentState.changeTokenData, Data([0x11]))
    }

    // MARK: - Per-host live-session routing (plumbed through to ReWakeRouting)

    func testForegroundWakeForADifferentHostPostsInsteadOfVanishing() async {
        let recorder = Recorder()
        let handler = makeHandler(
            recorder: recorder,
            fetch: ReWakeFetchOutcome(status: .ok, beacons: [beacon()]),
            isForeground: true,
            hasLiveSession: true,
            liveSessionPinHex: String(repeating: "c", count: 64)) // live session on ANOTHER Mac

        let outcome = await handler.run()

        XCTAssertEqual(outcome, .newData)
        XCTAssertTrue(recorder.kickedPinHexes.isEmpty) // never stomp the live session
        XCTAssertEqual(recorder.postedBeacons.map(\.recordName), [pin]) // but the wake surfaces
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

    func testDeadlineDoesNotAwaitANonCancellationCooperativeStraggler() async {
        // The 8n1.3 review headline: a wedged CloudKit call ignores cancellation entirely. The
        // deadline must resume the caller anyway — a task-group race would await the straggler
        // child and starve the push completion handler past the ~30 s watchdog.
        let start = ContinuousClock.now
        let result = await ReWakeDeadline.run(seconds: 0.1) { () -> Bool? in
            await withCheckedContinuation { (_: CheckedContinuation<Bool?, Never>) in }
        }
        XCTAssertNil(result)
        XCTAssertLessThan(start.duration(to: .now), .seconds(5))
    }
}

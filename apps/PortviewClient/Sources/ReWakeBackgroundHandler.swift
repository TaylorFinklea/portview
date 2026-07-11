// SPDX-License-Identifier: Apache-2.0
import Foundation
import PortviewClientCore

/// Outcome of one CloudKit zone-changes fetch, decoded at the CK edge (`ReWakeCenter`) into pure
/// values so the handler below never imports CloudKit.
struct ReWakeFetchOutcome: Equatable {
    enum Status: Equatable {
        /// Changes fetched; `beacons` and `changeTokenData` are valid.
        case ok
        /// `PortviewSignals` doesn't exist yet (phone-first install order) — not an error, the host
        /// hasn't written its first beacon; try again on a later push.
        case zoneNotReady
        /// The stored change token expired server-side; it must be discarded and the next fetch
        /// starts from scratch.
        case tokenExpired
        /// Anything else (network, iCloud down, no account) — retry on the next push, token untouched.
        case failure
    }

    var status: Status
    var beacons: [HostBeaconRecord] = []
    var changeTokenData: Data? = nil
}

/// Orchestrates ONE silent push end-to-end — fetch changes → `ReWakeDecision` per beacon → bounded
/// reachability probe → `ReWakeRouting` resolution — with every effect injected, so the whole flow
/// is simulator-testable without CloudKit, APNs, or notifications.
///
/// `run()` is TOTAL and non-throwing by construction: every fetch status, decision, and probe
/// outcome falls through to a returned `Outcome`, which is what lets the app delegate call the
/// silent-push completion handler unconditionally on every path (the classic silent-push killer is
/// a missed path — see `ReWakeAppDelegate`).
@MainActor
struct ReWakeBackgroundHandler {
    enum Outcome: Equatable {
        case newData, noData, failed
    }

    var loadState: () -> ReWakeState
    var saveState: (ReWakeState) -> Void
    var savedHosts: () -> [ReWakeDecision.SavedHost]
    var fetchChanges: (Data?) async -> ReWakeFetchOutcome
    /// Bounded (≤5 s) pinned reachability dial; the beacon rides along so the edge can prefer a
    /// live Bonjour re-resolve of the host by name over the stale saved address.
    var probe: (HostBeaconRecord, ReWakeDecision.Endpoint, String) async -> Bool
    var isForeground: () -> Bool
    var hasLiveSession: () -> Bool
    var postNotification: (HostBeaconRecord) async -> Void
    /// Foreground path: enter the existing in-app saved-Mac reconnect flow for this pin hex.
    var kickReconnect: (String) -> Void
    var now: () -> Date = { Date() }

    func run() async -> Outcome {
        var state = loadState()
        let fetched = await fetchChanges(state.changeTokenData)
        switch fetched.status {
        case .zoneNotReady:
            return .noData // host hasn't created the zone yet — silently not-ready, no state change
        case .tokenExpired:
            state.changeTokenData = nil
            saveState(state)
            return .failed // next push refetches the zone from scratch
        case .failure:
            return .failed // token deliberately not advanced; the next push retries
        case .ok:
            break
        }
        if let token = fetched.changeTokenData {
            state.changeTokenData = token
        }

        let hosts = savedHosts()
        var kicked = false
        for beacon in fetched.beacons {
            let action = ReWakeDecision.evaluate(
                beacon: beacon,
                savedHosts: hosts,
                lastHandledEpochs: state.lastHandledEpochs,
                lastActedAt: state.lastActedAt,
                now: now())
            guard case .reachabilityProbe(let endpoint, let pin) = action else { continue }
            // Acting = probing: stamp BOTH per-host maps (epoch dedupe + rate-limit clock) before
            // the dial, and persist immediately, so a burst of pushes can't re-probe this beacon
            // even if the background window is killed mid-flight.
            state.markActed(on: beacon, at: now())
            saveState(state)
            let reachable = await probe(beacon, endpoint, pin)
            switch ReWakeRouting.resolve(
                probeSucceeded: reachable, isForeground: isForeground(), hasLiveSession: hasLiveSession()) {
            case .staySilent:
                break
            case .reconnectInApp:
                // One kick per push even if several Macs became reachable — a second kick would
                // cancel the reconnect the first one just started.
                if !kicked {
                    kickReconnect(beacon.recordName)
                    kicked = true
                }
            case .postNotification:
                await postNotification(beacon)
            }
        }
        saveState(state) // persists the advanced change token (and any acted-on stamps)
        return .newData
    }
}

/// Maps a tapped re-wake notification (whose payload carries the beacon's `recordName` — the host
/// pin fingerprint hex) back to the saved Mac it announces, so the tap can enter the normal
/// saved-Mac reconnect flow (`SessionViewModel.reconnect(saved:discovered:)`, whose
/// `SavedHost.reconnectEndpoints(among:)` prefers a live Bonjour re-resolve over the saved IP).
enum ReWakeTapRouting {
    static func savedHost(forPinHex pinHex: String, in hosts: [SavedHost]) -> SavedHost? {
        hosts.first { $0.pinHex == pinHex }
    }
}

/// Runs an async operation under a hard wall-clock deadline, returning nil if it doesn't finish in
/// time. Guards the silent-push budget: the reachability dial and the whole push handler are both
/// bounded so the fetch completion handler can never be starved by a hung network call.
enum ReWakeDeadline {
    static func run<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

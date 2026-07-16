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
    /// The pin fingerprint hex of the host the live session is connected to (nil when unknown, e.g.
    /// mid-connect) — lets routing suppress only the SAME host's wake instead of every wake.
    var liveSessionPinHex: () -> String? = { nil }
    var postNotification: (HostBeaconRecord) async -> Void
    /// Foreground path: enter the existing in-app saved-Mac reconnect flow for this pin hex.
    var kickReconnect: (String) -> Void
    var now: () -> Date = { Date() }

    func run() async -> Outcome {
        var fetched = await fetchChanges(loadState().changeTokenData)
        if fetched.status == .tokenExpired {
            // Discard the expired token AND retry from scratch in the SAME run — returning here
            // would drop the very wake that triggered this push (the system never redelivers it).
            persist { $0.changeTokenData = nil }
            fetched = await fetchChanges(nil)
        }
        switch fetched.status {
        case .zoneNotReady:
            return .noData // host hasn't created the zone yet — silently not-ready, no state change
        case .tokenExpired:
            return .failed // expired again straight after a from-scratch fetch — give up this push
        case .failure:
            return .failed // token deliberately not advanced; the next push retries
        case .ok:
            break
        }

        let hosts = savedHosts()
        var kicked = false
        for beacon in fetched.beacons {
            // Fresh state each iteration: this run's own stamps AND any concurrent writer's
            // updates (one-time flags from a foreground refresh) feed the next decision — a stale
            // whole-struct copy would clobber them at save time.
            let state = loadState()
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
            let actedAt = now()
            persist { $0.markActed(on: beacon, at: actedAt) }
            let reachable = await probe(beacon, endpoint, pin)
            switch ReWakeRouting.resolve(
                probeSucceeded: reachable,
                isForeground: isForeground(),
                hasLiveSession: hasLiveSession(),
                liveSessionPinHex: liveSessionPinHex(),
                beaconPinHex: beacon.recordName) {
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
        // The advanced token is persisted only after the WHOLE batch was processed: a kill
        // mid-batch then refetches the same changes, and the epoch dedupe skips the beacons
        // already acted on — persisting it earlier would permanently drop the later hosts' wakes.
        if let token = fetched.changeTokenData {
            persist { $0.changeTokenData = token }
        }
        return .newData
    }

    /// Narrow read-modify-write: reload, apply one delta, save — atomic on the MainActor (no
    /// suspension inside), so this run's saves never clobber state written by a concurrent writer
    /// (foreground refresh flags) or by its own earlier iterations.
    private func persist(_ mutate: (inout ReWakeState) -> Void) {
        var fresh = loadState()
        mutate(&fresh)
        saveState(fresh)
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
///
/// The deadline is UNCONDITIONAL: the caller resumes at the deadline even when the operation is
/// not cancellation-cooperative (a task-group race awaits ALL children, so one wedged CloudKit
/// call would hold it past the budget — the 8n1.3 review's headline finding). The losing
/// operation is cancelled best-effort and may still finish in the background; its effects must be
/// (and are) idempotent narrow state writes.
enum ReWakeDeadline {
    /// First-resume-wins guard: exactly one of the two racers resumes the continuation.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }
    }

    static func run<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        let once = Once()
        return await withCheckedContinuation { continuation in
            let work = Task {
                let value = await operation()
                if once.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if once.claim() {
                    continuation.resume(returning: nil)
                    work.cancel() // best-effort: a cooperative straggler stops early
                }
            }
        }
    }
}

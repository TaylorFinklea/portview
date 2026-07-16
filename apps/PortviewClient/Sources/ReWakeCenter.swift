// SPDX-License-Identifier: Apache-2.0
import CloudKit
import Foundation
import Network
import PortviewClientCore
import PortviewTransport
import UserNotifications

/// Persists `ReWakeState` as UserDefaults JSON — the same idiom as `SavedHostsStore`.
struct ReWakeStateStore {
    private let defaultsKey = "portview.rewakeState"
    private let defaults = UserDefaults.standard

    func load() -> ReWakeState {
        ReWakeState.decoded(from: defaults.data(forKey: defaultsKey))
    }

    func save(_ state: ReWakeState) {
        defaults.set(state.encoded(), forKey: defaultsKey)
    }
}

/// App-edge coordinator for CloudKit re-wake (spec §2/§2a): owns the idempotent zone + subscription
/// bootstrap, the zone-changes fetch, the bounded pinned reachability probe, the local "ready to
/// resume" notification, and the one-time notification-authorization request. ALL CloudKit types
/// stay in this file — the decision flow it feeds (`ReWakeBackgroundHandler`) is pure.
///
/// Every CloudKit failure here is soft: iCloud being down, a missing account, or the zone not
/// existing yet (phone-first install order) leaves the feature silently unavailable and is retried
/// on the next foreground — it never blocks pairing, streaming, or manual reconnect.
@MainActor
final class ReWakeCenter: ObservableObject {
    static let shared = ReWakeCenter()

    nonisolated static let containerIdentifier = "iCloud.dev.finklea.portview"
    nonisolated static let zoneName = "PortviewSignals"
    nonisolated static let subscriptionID = "portview-signals-rewake"
    nonisolated static let beaconRecordType = "HostBeacon"
    /// userInfo key on the local notification carrying the beacon's `recordName` (= the host pin
    /// fingerprint hex) so a tap can select the saved Mac to reconnect.
    nonisolated static let notificationPinHexKey = "portviewReWakePinHex"

    /// Hard ceiling on one push's total handling (fetch + probe + post) — comfortably inside the
    /// ~30 s background budget so the completion handler is never starved.
    nonisolated private static let pushBudget: TimeInterval = 25
    /// Spec §2 step 3: the reachability dial is bounded ≤5 s.
    nonisolated private static let probeBudget: TimeInterval = 5
    /// How long the probe waits for a live Bonjour re-resolve of the host before falling back to
    /// the saved address (inside the overall probe budget).
    nonisolated private static let probeRediscoverTimeout: Duration = .seconds(2)

    /// Set when a re-wake should enter the saved-Mac reconnect flow — a notification tap, or a
    /// push that arrived while the app was foreground. ContentView observes it and routes into
    /// `SessionViewModel.reconnect(saved:discovered:)`.
    @Published var pendingReconnectPinHex: String?
    /// One-time passive hint that notifications are denied, so background re-wake can't surface
    /// (spec §2a.5: the feature is inert; hint once, never block).
    @Published private(set) var notificationsDeniedHint = false

    /// Installed by ContentView: whether a session is currently connecting/streaming/reconnecting,
    /// so a foreground push never stomps a live session with a kicked reconnect.
    var hasLiveSession: () -> Bool = { false }
    /// Installed by ContentView: the pin fingerprint hex of the host the live session is connected
    /// to (nil when unknown), so routing suppresses only that host's own wake.
    var liveSessionPinHex: () -> String? = { nil }

    private let stateStore = ReWakeStateStore()
    private var bootstrapped = false
    private var bootstrapInFlight = false
    private var authRequestInFlight = false
    /// The most recent push handling; each new push chains behind it (same pattern as the host's
    /// beacon-write chain): two overlapping silent pushes would otherwise interleave the handler's
    /// load→await→save sections — double-probing the same beacon past the dedupe/rate limit,
    /// double-notifying, and clobbering each other's persisted change token.
    private var pushChain: Task<ReWakeBackgroundHandler.Outcome, Never>?

    /// Launch entry (from the app delegate): kick the auth request + zone/subscription bootstrap
    /// without blocking launch.
    func onLaunch() {
        Task { await self.refresh() }
    }

    /// Idempotent — safe to call at launch, on every foreground return, and after a pairing saves
    /// its first host (the moment the feature starts to matter).
    func refresh() async {
        await requestAuthorizationIfNeeded()
        await bootstrapIfNeeded()
        await refreshDeniedHint()
    }

    /// Handles one remote notification to completion. Total and non-throwing, and bounded by a
    /// hard deadline well inside the ~30 s background budget — the app delegate can therefore call
    /// the fetch completion handler unconditionally with the returned outcome on EVERY path.
    ///
    /// `isForeground` is a CLOSURE read at routing time, not a snapshot at push arrival: handling
    /// spans a fetch plus a ≤5 s probe, and an app-state transition mid-handling would otherwise
    /// mis-route (a background→foreground flip posts a notification the foreground delegate then
    /// suppresses — the wake silently vanishes).
    func handlePush(isForeground: @escaping @MainActor () -> Bool) async -> ReWakeBackgroundHandler.Outcome {
        let handler = ReWakeBackgroundHandler(
            loadState: { [stateStore] in stateStore.load() },
            saveState: { [stateStore] in stateStore.save($0) },
            savedHosts: {
                SavedHostsStore.snapshot().map { ReWakeDecision.SavedHost(pinHex: $0.pinHex, host: $0.host) }
            },
            fetchChanges: { token in await Self.fetchZoneChanges(since: token) },
            probe: { beacon, endpoint, pin in
                await Self.probeReachability(beacon: beacon, endpoint: endpoint, pinHex: pin)
            },
            isForeground: isForeground,
            hasLiveSession: { [weak self] in self?.hasLiveSession() ?? false },
            liveSessionPinHex: { [weak self] in self?.liveSessionPinHex() },
            postNotification: { [weak self] beacon in await self?.postReadyNotification(for: beacon) },
            kickReconnect: { [weak self] pinHex in self?.pendingReconnectPinHex = pinHex })
        // Chain this push behind the previous one so handler runs never interleave; the deadline
        // covers the WAIT TOO (a stacked push must not inherit its predecessor's spent budget and
        // starve its own completion handler). The chained run itself finishes on its own clock —
        // its narrow state writes stay serialized even when the caller has already returned.
        let previous = pushChain
        let run = Task { () -> ReWakeBackgroundHandler.Outcome in
            _ = await previous?.value
            return await handler.run()
        }
        pushChain = run
        let outcome = await ReWakeDeadline.run(seconds: Self.pushBudget) { () -> ReWakeBackgroundHandler.Outcome? in
            await run.value
        }
        return outcome ?? .failed
    }

    // MARK: - Bootstrap (zone + subscription)

    private func bootstrapIfNeeded() async {
        guard !bootstrapped, !bootstrapInFlight else { return }
        bootstrapInFlight = true
        defer { bootstrapInFlight = false }
        let database = CKContainer(identifier: Self.containerIdentifier).privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
        do {
            // Idempotent zone save first (spec §0): on the phone-first install order the zone does
            // not exist yet, and a CKRecordZoneSubscription cannot be saved against a missing zone.
            let zoneResults = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
            for result in zoneResults.saveResults.values { _ = try result.get() }

            let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: Self.subscriptionID)
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true // silent push only — no alert/badge/sound
            subscription.notificationInfo = info
            let subResults = try await database.modifySubscriptions(saving: [subscription], deleting: [])
            for result in subResults.saveResults.values { _ = try result.get() }
            bootstrapped = true
        } catch {
            // Not-ready (zoneNotFound), no iCloud account, network down — all soft: the feature is
            // silently unavailable and this retries on the next foreground. Never surfaces an error.
        }
    }

    // MARK: - Notification authorization (§2a.5)

    /// Requests notification authorization ONCE, and only once the feature can matter (a paired
    /// Mac exists) — never a cold-launch permission ambush, never a re-prompt.
    private func requestAuthorizationIfNeeded() async {
        let state = stateStore.load()
        guard !state.didRequestNotificationAuth else { return }
        guard !SavedHostsStore.snapshot().isEmpty else { return }
        guard !authRequestInFlight else { return } // refresh() fires on every foreground return
        authRequestInFlight = true
        defer { authRequestInFlight = false }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        // Burn the one-shot only once the request RESOLVED to an answer: persisting before it
        // resolves (or when it errored out still .notDetermined) would — on one kill/interrupt
        // mid-prompt — leave the feature inert forever with the user never actually asked.
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus != .notDetermined else { return }
        var fresh = stateStore.load()
        fresh.didRequestNotificationAuth = true
        stateStore.save(fresh)
    }

    /// Surfaces the one-time passive "notifications are off → re-wake is inert" hint when the user
    /// has denied authorization after we asked.
    private func refreshDeniedHint() async {
        let state = stateStore.load()
        guard state.didRequestNotificationAuth, !state.didShowDeniedHint else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .denied {
            markDeniedHint()
        }
    }

    private func markDeniedHint() {
        var state = stateStore.load()
        guard !state.didShowDeniedHint else { return }
        state.didShowDeniedHint = true
        stateStore.save(state)
        notificationsDeniedHint = true
    }

    // MARK: - Local notification (the user-visible deliverable)

    private func postReadyNotification(for beacon: HostBeaconRecord) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            // Posting without authorization is silently dropped (spec §2a.5). The one-time hint
            // is NOT burned here — this path usually runs backgrounded, where marking the hint
            // "shown" loses it if the app is terminated before the user ever sees Deck Home; the
            // next foreground `refreshDeniedHint()` detects the denied state and surfaces it.
            return
        }
        let content = UNMutableNotificationContent()
        // The hostName is attacker-influenced CloudKit data (anyone with the user's iCloud access
        // aside, a compromised host writes arbitrary text): strip control characters and cap the
        // length so the lock-screen line can't be shaped into a fake system prompt.
        let cleaned = beacon.hostName
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = cleaned.isEmpty ? "Your Mac" : String(cleaned.prefix(64))
        content.title = "\(displayName) is ready"
        content.body = "Tap to resume your Portview session."
        content.userInfo = [Self.notificationPinHexKey: beacon.recordName]
        // One pending notification per host: a newer beacon replaces the older alert.
        let request = UNNotificationRequest(
            identifier: "portview-rewake-\(beacon.recordName)", content: content, trigger: nil)
        try? await center.add(request)
    }

    // MARK: - Zone-changes fetch (CK edge → pure ReWakeFetchOutcome)

    nonisolated private static func fetchZoneChanges(since tokenData: Data?) async -> ReWakeFetchOutcome {
        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        var configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        configuration.previousServerChangeToken = tokenData.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
        }

        /// CK operation callbacks arrive on arbitrary queues; accumulate under a lock.
        final class Accumulator: @unchecked Sendable {
            let lock = NSLock()
            var beacons: [HostBeaconRecord] = []
            var tokenData: Data?
            var zoneStatus: ReWakeFetchOutcome.Status?
        }
        let accumulated = Accumulator()

        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zoneID], configurationsByRecordZoneID: [zoneID: configuration])
        operation.recordWasChangedBlock = { recordID, result in
            guard case .success(let record) = result, record.recordType == beaconRecordType else { return }
            var fields: [String: Any] = [:]
            for key in record.allKeys() { fields[key] = record[key] }
            guard let beacon = HostBeaconRecord(recordName: recordID.recordName, fields: fields) else { return }
            accumulated.lock.withLock { accumulated.beacons.append(beacon) }
        }
        operation.recordZoneFetchResultBlock = { _, result in
            switch result {
            case .success(let fetch):
                let data = try? NSKeyedArchiver.archivedData(
                    withRootObject: fetch.serverChangeToken, requiringSecureCoding: true)
                accumulated.lock.withLock { accumulated.tokenData = data }
            case .failure(let error):
                accumulated.lock.withLock { accumulated.zoneStatus = fetchStatus(for: error) }
            }
        }
        operation.qualityOfService = .userInitiated
        // Cancellation-cooperative (8n1.3 review): `CKOperation.cancel()` finishes the operation
        // with `operationCancelled`, which fires the result block exactly once and resumes the
        // continuation — so a deadline/cancel actually frees this call (and iOS's push budget)
        // instead of riding CloudKit's own ~60 s timeout with a zombie fetch.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                operation.fetchRecordZoneChangesResultBlock = { result in
                    let (beacons, tokenData, zoneStatus) = accumulated.lock.withLock {
                        (accumulated.beacons, accumulated.tokenData, accumulated.zoneStatus)
                    }
                    switch result {
                    case .success:
                        continuation.resume(returning: ReWakeFetchOutcome(
                            status: zoneStatus ?? .ok, beacons: beacons, changeTokenData: tokenData))
                    case .failure(let error):
                        continuation.resume(returning: ReWakeFetchOutcome(status: zoneStatus ?? fetchStatus(for: error)))
                    }
                }
                database.add(operation)
            }
        } onCancel: {
            operation.cancel()
        }
    }

    nonisolated private static func fetchStatus(for error: Error) -> ReWakeFetchOutcome.Status {
        guard let ckError = error as? CKError else { return .failure }
        if ckError.code == .partialFailure,
           let partial = ckError.partialErrorsByItemID?.values.compactMap({ $0 as? CKError }).first {
            return fetchStatus(for: partial)
        }
        switch ckError.code {
        case .zoneNotFound, .userDeletedZone:
            return .zoneNotReady // phone-first install order: the host hasn't written a beacon yet
        case .changeTokenExpired:
            return .tokenExpired
        default:
            return .failure
        }
    }

    // MARK: - Reachability probe (bounded ≤5 s, pinned)

    /// Confirms the host is actually reachable before promising the user a working resume. Prefers
    /// a live Bonjour re-resolve of the saved Mac by name (a DHCP move after reboot is the common
    /// case — the saved IP may be stale) and falls back to the saved address with the beacon's
    /// freshly-reported port. Certificate pinning gates every dial, so a wrong same-named Mac can
    /// never probe as reachable.
    nonisolated private static func probeReachability(
        beacon: HostBeaconRecord,
        endpoint: ReWakeDecision.Endpoint,
        pinHex: String
    ) async -> Bool {
        guard let pin = Data(hexString: pinHex), pin.count == 32 else { return false }
        let bonjourName = SavedHostsStore.snapshot().first { $0.pinHex == pinHex }?.name ?? beacon.hostName
        let outcome = await ReWakeDeadline.run(seconds: probeBudget) { () -> Bool? in
            var candidates: [NWEndpoint] = []
            if let match = await rediscover(name: bonjourName, timeout: probeRediscoverTimeout) {
                candidates.append(match.endpoint)
            }
            if let port = NWEndpoint.Port(rawValue: UInt16(clamping: endpoint.port)) {
                candidates.append(.hostPort(host: NWEndpoint.Host(endpoint.host), port: port))
            }
            for candidate in candidates {
                if Task.isCancelled { return false }
                guard let connection = try? await PortviewClientSession.connectQUIC(
                    to: candidate, pinnedCertificateSHA256: pin) else { continue }
                connection.close()
                return true
            }
            return false
        }
        return outcome ?? false
    }

    /// Browse Bonjour briefly for a host named `name` (same shape as `SessionViewModel.rediscover`,
    /// but tighter — it must fit inside the probe budget).
    nonisolated private static func rediscover(name: String, timeout: Duration) async -> DiscoveredHost? {
        let browser = PortviewBrowser()
        browser.start()
        return await withTaskGroup(of: DiscoveredHost?.self) { group in
            group.addTask {
                for await hosts in browser.hosts {
                    if let match = hosts.first(where: { $0.name == name }) { return match }
                }
                return nil // stream finished without a match
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil // timeout sentinel
            }
            let first = await group.next() ?? nil
            browser.stop() // finish the stream so the browse task's `for await` ends
            group.cancelAll()
            for await _ in group {} // drain the now-finishing tasks
            return first
        }
    }
}

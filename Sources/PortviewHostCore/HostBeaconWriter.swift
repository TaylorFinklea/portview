// SPDX-License-Identifier: Apache-2.0
import Foundation
import PortviewClientCore
import os

private let logger = Logger(subsystem: "dev.finklea.portview", category: "beacon")

/// Storage seam for the host's CloudKit `HostBeacon` upserts (spec:
/// `docs/superpowers/specs/2026-07-01-cloudkit-rewake.md` §0-§1). The CloudKit-backed implementation
/// lives at the host-app edge (`CloudKitBeaconStore` in `apps/PortviewHost/Sources`); tests inject an
/// in-memory store so the writer's trigger/epoch/retry policy is package-testable without CloudKit.
public protocol BeaconStore: Sendable {
    /// Idempotently create the `PortviewSignals` custom zone (a `CKModifyRecordZonesOperation` at the
    /// CK edge). Must be safe to call when the zone already exists.
    func createZone() async throws
    /// Upsert the beacon record by its `recordName`. The CK edge MUST save with policy `.changedKeys`
    /// — the `.ifServerRecordUnchanged` default fails every write after the first (spec §1). Throw
    /// `BeaconStoreError.zoneNotFound` when the zone is missing so the writer can create-then-retry.
    func save(_ beacon: HostBeaconRecord) async throws
}

/// The one store failure `HostBeaconWriter` treats specially: every other error is log-and-drop, but
/// a missing zone triggers create-then-retry (spec §0 — zone creation is the HOST's job; the client's
/// subscription bootstrap only tolerates its absence).
public enum BeaconStoreError: Error, Equatable {
    case zoneNotFound
}

/// Writes the host's `HostBeacon` record ("I am reachable") into the shared CloudKit zone, purely in
/// response to explicit triggers (spec §1):
///
/// - `hostingStarted` — the host bound its listener and is advertising,
/// - `portChanged` — the persisted listening port changed while hosting,
/// - `requestReconnect` — the user clicked the menu-bar "Ask iPhone to reconnect" (`wantsReconnect=1`).
///
/// NEVER on a timer — every write rides the phone's silent-push budget, so this type deliberately owns
/// no clock/timer/loop; zero triggers means zero writes. Writes are fire-and-forget with exactly one
/// retry and never throw: CloudKit being down must never affect hosting, so callers fire each trigger
/// from its own task (the app edge does `Task { await writer.… }`) and errors are logged and dropped —
/// except `zoneNotFound`, which triggers an idempotent zone create before the single retry.
///
/// `epoch` is wall-clock micros bumped to stay strictly increasing per write — explicitly NOT host
/// uptime (do not copy the `systemUptime` Ping idiom in HostRunner.swift): uptime resets to ~0 on
/// reboot, so the client's `epoch <= lastHandled → ignore` dedupe would silently eat every legitimate
/// wake for days after a restart — precisely the reboot scenario this feature exists for. Wall clock
/// restores sane ordering after a reboot without persisted state, modulo a backward clock step across
/// the reboot (NTP/manual): routine beacons can then read stale client-side until the clock passes the
/// old value, and an explicit nudge — which bypasses the client's epoch dedupe — is the backstop.
public actor HostBeaconWriter {
    private struct Identity {
        var pinHex: String
        var hostName: String
        var port: UInt16
    }

    private let store: BeaconStore
    private let now: @Sendable () -> Date
    /// Whether `createZone` has succeeded once (spec §0: create immediately before the FIRST beacon
    /// write). Only set on success so a failed create is re-attempted on the next trigger.
    private var zoneCreated = false
    /// Last epoch handed out, so same-instant writes still increase strictly.
    private var lastEpoch: Int64 = 0
    private var identity: Identity?
    /// The most recently enqueued write; each new write chains behind it (bead e00). The actor is
    /// reentrant at `await store.save`, so without the chain two in-flight writes could complete in
    /// either order and CloudKit's last-writer-wins upsert would keep the STALE beacon (old port,
    /// swallowed nudge) until the next trigger.
    private var lastWrite: Task<Void, Never>?

    /// - Parameter now: injectable wall clock (tests drive it manually; production uses `Date.init`).
    public init(store: BeaconStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    /// Trigger: hosting became ready. `pinHex` is the host pin fingerprint hex the runner already
    /// computed for the pairing payload (`HostReadyDetails.pinHex` — SHA-256 of the persistent TLS
    /// leaf cert DER); it becomes the beacon's `recordName`, matching what the client's saved-host
    /// store dedupes on. Remembered for later `portChanged`/`requestReconnect` triggers.
    public func hostingStarted(pinHex: String, hostName: String, port: UInt16) async {
        identity = Identity(pinHex: pinHex, hostName: hostName, port: port)
        await write(wantsReconnect: false)
    }

    /// Trigger: the persisted listening port changed while hosting. Dropped if hosting never started.
    public func portChanged(_ port: UInt16) async {
        guard identity != nil else { return }
        identity?.port = port
        await write(wantsReconnect: false)
    }

    /// Trigger: the user asked the iPhone to reconnect (menu-bar nudge) — writes `wantsReconnect = 1`
    /// so the client distinguishes it from a routine liveness update. Dropped if hosting never started.
    public func requestReconnect() async {
        await write(wantsReconnect: true)
    }

    private func nextEpoch() -> Int64 {
        let wallClockMicros = Int64(now().timeIntervalSince1970 * 1_000_000)
        lastEpoch = max(wallClockMicros, lastEpoch + 1)
        return lastEpoch
    }

    /// Builds the beacon — minting its epoch — SYNCHRONOUSLY, so trigger order fixes epoch order,
    /// then chains the store write behind the previous one: writes land strictly in epoch order no
    /// matter how CloudKit reorders completions (bead e00). Returns once THIS write has landed (or
    /// been dropped), preserving the caller-awaits-its-own-trigger contract.
    private func write(wantsReconnect: Bool) async {
        guard let identity else { return }
        let beacon = HostBeaconRecord(
            recordName: identity.pinHex,
            hostName: identity.hostName,
            port: Int64(identity.port),
            epoch: nextEpoch(),
            wantsReconnect: wantsReconnect ? 1 : 0)
        let previous = lastWrite
        let chained = Task {
            await previous?.value
            await self.performWrite(beacon)
        }
        lastWrite = chained
        await chained.value
    }

    private func performWrite(_ beacon: HostBeaconRecord) async {
        if !zoneCreated {
            await createZoneLogged()
        }
        do {
            try await store.save(beacon)
        } catch {
            // Fire-and-forget with exactly ONE retry; zoneNotFound re-creates the zone first (§0).
            if case BeaconStoreError.zoneNotFound = error {
                await createZoneLogged()
            }
            do {
                try await store.save(beacon)
            } catch {
                logger.warning("beacon write dropped after one retry: \(error, privacy: .public)")
            }
        }
    }

    private func createZoneLogged() async {
        do {
            try await store.createZone()
            zoneCreated = true
        } catch {
            // Log-and-drop: the save below surfaces zoneNotFound again and the next trigger retries.
            logger.warning("PortviewSignals zone create failed: \(error, privacy: .public)")
        }
    }
}

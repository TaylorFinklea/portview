// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import PortviewClientCore
@testable import PortviewHostCore

/// `HostBeaconWriter` writes the CloudKit `HostBeacon` record ONLY on explicit triggers (hosting
/// start, port change, "Ask iPhone to reconnect" nudge), with a wall-clock epoch that keeps ordering
/// across a host reboot, zone create-then-retry on `zoneNotFound`, exactly one retry per write, and
/// errors that never reach the caller. The store is injectable so all of this runs against an
/// in-memory fake — no CloudKit.
@Suite struct HostBeaconWriterTests {
    /// In-memory `BeaconStore`: models CloudKit's zone semantics (a save into a missing zone throws
    /// `zoneNotFound`; `createZone` is idempotent) and records every call so tests can assert exact
    /// call ordering and retry counts.
    private actor InMemoryBeaconStore: BeaconStore {
        enum Event: Equatable {
            case createZone
            case save(HostBeaconRecord)
        }

        private(set) var events: [Event] = []
        private(set) var zoneExists = false
        /// Successfully upserted beacons, in write order.
        private(set) var saved: [HostBeaconRecord] = []
        private var saveError: (any Error)?
        private var zoneCreateError: (any Error)?

        func createZone() throws {
            events.append(.createZone)
            if let zoneCreateError { throw zoneCreateError }
            zoneExists = true
        }

        func save(_ beacon: HostBeaconRecord) throws {
            events.append(.save(beacon))
            if let saveError { throw saveError }
            guard zoneExists else { throw BeaconStoreError.zoneNotFound }
            saved.append(beacon)
        }

        // Test controls.
        func deleteZone() { zoneExists = false }
        func setSaveError(_ error: (any Error)?) { saveError = error }
        func setZoneCreateError(_ error: (any Error)?) { zoneCreateError = error }

        var saveAttempts: Int {
            events.count { if case .save = $0 { true } else { false } }
        }
    }

    /// Manually-advanced wall clock injected as the writer's `now` (no real time dependence).
    private final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        init(_ date: Date) { self.date = date }
        func advance(by seconds: TimeInterval) {
            lock.lock(); date = date.addingTimeInterval(seconds); lock.unlock()
        }
        var now: @Sendable () -> Date {
            { [self] in lock.lock(); defer { lock.unlock() }; return date }
        }
    }

    private struct TestError: Error {}

    private static let start = Date(timeIntervalSince1970: 1_750_000_000)

    private func makeWriter() -> (HostBeaconWriter, InMemoryBeaconStore, ManualClock) {
        let store = InMemoryBeaconStore()
        let clock = ManualClock(Self.start)
        return (HostBeaconWriter(store: store, now: clock.now), store, clock)
    }

    // MARK: Triggers + record fields

    @Test func hostingStartCreatesZoneThenWritesBeacon() async {
        let (writer, store, _) = makeWriter()
        await writer.hostingStarted(pinHex: "ab12cd", hostName: "Studio", port: 4242)

        // Zone create (idempotent) happens BEFORE the first beacon write (spec §0).
        let events = await store.events
        #expect(events.first == .createZone)
        #expect(await store.saveAttempts == 1)

        let saved = await store.saved
        #expect(saved.count == 1)
        #expect(saved[0].recordName == "ab12cd") // the host pin fingerprint hex, not a new derivation
        #expect(saved[0].hostName == "Studio")
        #expect(saved[0].port == 4242)
        #expect(saved[0].wantsReconnect == 0)
        // Wall-clock micros — NOT host uptime (which would be a tiny near-zero value after a boot).
        #expect(saved[0].epoch == Int64(Self.start.timeIntervalSince1970 * 1_000_000))
    }

    @Test func portChangeWritesUpdatedPort() async {
        let (writer, store, clock) = makeWriter()
        await writer.hostingStarted(pinHex: "ab12cd", hostName: "Studio", port: 4242)
        clock.advance(by: 1)
        await writer.portChanged(5001)

        let saved = await store.saved
        #expect(saved.count == 2)
        #expect(saved[1].port == 5001)
        #expect(saved[1].wantsReconnect == 0)
        #expect(saved[1].recordName == "ab12cd")
        #expect(saved[1].epoch > saved[0].epoch)
    }

    @Test func reconnectNudgeSetsWantsReconnect() async {
        let (writer, store, clock) = makeWriter()
        await writer.hostingStarted(pinHex: "ab12cd", hostName: "Studio", port: 4242)
        clock.advance(by: 1)
        await writer.requestReconnect()

        let saved = await store.saved
        #expect(saved.count == 2)
        #expect(saved[1].wantsReconnect == 1)
        #expect(saved[1].hostName == "Studio")
        #expect(saved[1].port == 4242)
    }

    @Test func triggersBeforeHostingStartAreDropped() async {
        let (writer, store, _) = makeWriter()
        await writer.requestReconnect()
        await writer.portChanged(5001)
        #expect(await store.events.isEmpty)
    }

    @Test func subsequentWritesSkipZoneCreate() async {
        let (writer, store, _) = makeWriter()
        await writer.hostingStarted(pinHex: "ab12cd", hostName: "Studio", port: 4242)
        await writer.requestReconnect()
        await writer.portChanged(5001)
        let creates = await store.events.count { $0 == .createZone }
        #expect(creates == 1)
    }

    // MARK: Epoch (wall clock, reboot ordering)

    /// The load-bearing across-reboot behavior (spec §1): a fresh writer instance — all in-memory
    /// state gone, as after a host reboot — still produces epochs ABOVE every pre-reboot write,
    /// because the epoch is wall-clock derived. A `systemUptime`-style epoch would reset to ~0 here
    /// and the client's `epoch <= lastHandled` dedupe would eat every wake for days.
    @Test func epochOrdersWritesAcrossReboot() async {
        let store = InMemoryBeaconStore()
        let clock = ManualClock(Self.start)

        let beforeReboot = HostBeaconWriter(store: store, now: clock.now)
        await beforeReboot.hostingStarted(pinHex: "ab12cd", hostName: "Studio", port: 4242)

        clock.advance(by: 90) // the reboot takes a moment; wall clock keeps moving
        let afterReboot = HostBeaconWriter(store: store, now: clock.now) // fresh process state
        await afterReboot.hostingStarted(pinHex: "ab12cd", hostName: "Studio", port: 4242)

        let saved = await store.saved
        #expect(saved.count == 2)
        #expect(saved[1].epoch > saved[0].epoch)
    }

    @Test func epochStrictlyIncreasesEvenWhenClockStalls() async {
        let (writer, store, _) = makeWriter() // clock never advanced between writes
        await writer.hostingStarted(pinHex: "ab12cd", hostName: "Studio", port: 4242)
        await writer.requestReconnect()
        await writer.requestReconnect()
        let epochs = await store.saved.map(\.epoch)
        #expect(epochs.count == 3)
        #expect(epochs[1] > epochs[0])
        #expect(epochs[2] > epochs[1])
    }

    // MARK: zoneNotFound → create-then-retry

    @Test func zoneNotFoundCreatesZoneThenRetriesExactlyOnce() async {
        let (writer, store, _) = makeWriter()
        await writer.hostingStarted(pinHex: "ab12cd", hostName: "Studio", port: 4242)
        await store.deleteZone() // e.g. the zone was purged server-side after the first write

        await writer.requestReconnect()

        let saved = await store.saved
        #expect(saved.count == 2)
        #expect(saved[1].wantsReconnect == 1)

        // The nudge's sequence: save (zoneNotFound) → createZone → ONE retry (succeeds), appended to
        // the first write's [createZone, save].
        let events = await store.events
        #expect(events.count == 5)
        if case .save(let failedAttempt) = events[2] {
            #expect(failedAttempt == saved[1]) // the retry re-saves the SAME beacon
        } else {
            Issue.record("expected the nudge's first save attempt at events[2], got \(events[2])")
        }
        #expect(events[3] == .createZone)
        #expect(events[4] == .save(saved[1]))
    }

    /// A store that keeps failing gets exactly ONE retry per trigger — never a retry loop.
    @Test func persistentFailureStopsAfterExactlyOneRetry() async {
        let (writer, store, _) = makeWriter()
        await store.setZoneCreateError(TestError()) // zone can never be created → saves keep failing
        await writer.hostingStarted(pinHex: "ab12cd", hostName: "Studio", port: 4242)

        #expect(await store.saveAttempts == 2) // the write + exactly one retry
        #expect(await store.saved.isEmpty)     // dropped, not thrown
    }

    /// A failed zone create is not latched: the next trigger attempts the create again (the "before
    /// first write" create only counts once it SUCCEEDS).
    @Test func zoneCreateFailureIsRetriedOnNextTrigger() async {
        let (writer, store, _) = makeWriter()
        await store.setZoneCreateError(TestError())
        await writer.hostingStarted(pinHex: "ab12cd", hostName: "Studio", port: 4242)
        #expect(await store.saved.isEmpty)

        await store.setZoneCreateError(nil) // iCloud recovered
        await writer.requestReconnect()
        let saved = await store.saved
        #expect(saved.count == 1)
        #expect(saved[0].wantsReconnect == 1)
    }

    // MARK: Errors never propagate; writer keeps working

    @Test func storeErrorsNeverPropagateAndWriterRecovers() async {
        let (writer, store, _) = makeWriter()
        await store.setSaveError(TestError())
        // Non-throwing by signature; the failing store must not wedge the writer either.
        await writer.hostingStarted(pinHex: "ab12cd", hostName: "Studio", port: 4242)
        #expect(await store.saveAttempts == 2)
        #expect(await store.saved.isEmpty)

        await store.setSaveError(nil)
        await writer.portChanged(5001)
        let saved = await store.saved
        #expect(saved.count == 1)
        #expect(saved[0].port == 5001)
    }

    // MARK: Write chaining (bead e00)

    /// A `BeaconStore` whose saves can be HELD in flight and released later — models a slow
    /// CloudKit call so tests can interleave a second trigger while the first write is pending.
    private actor GatedBeaconStore: BeaconStore {
        private(set) var landed: [HostBeaconRecord] = []
        private var holdSaves = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func setHold(_ hold: Bool) { holdSaves = hold }
        func createZone() throws {}
        func save(_ beacon: HostBeaconRecord) async throws {
            if holdSaves {
                await withCheckedContinuation { waiting.append($0) }
            }
            landed.append(beacon)
        }
        /// Releases held saves in REVERSE arrival order — the CloudKit worst case (completion
        /// order is not request order), which is exactly what un-chained writes get wrong.
        func releaseAllReversed() {
            waiting.reversed().forEach { $0.resume() }
            waiting.removeAll()
        }
        var pendingCount: Int { waiting.count }
    }

    /// Two triggers while the store is slow: the second write must WAIT for the first (chained),
    /// never sit in flight beside it — otherwise CloudKit completion reordering lands the older
    /// epoch LAST and the beacon record regresses (stale port / lost nudge until the next write).
    @Test func inFlightWriteChainsTheNextTriggerBehindIt() async throws {
        let store = GatedBeaconStore()
        let clock = ManualClock(Self.start)
        let writer = HostBeaconWriter(store: store, now: clock.now)
        await writer.hostingStarted(pinHex: "ab12cd", hostName: "Studio", port: 4242)

        await store.setHold(true)
        let portWrite = Task { await writer.portChanged(5001) }
        for _ in 0..<10_000 where await store.pendingCount < 1 { await Task.yield() }
        #expect(await store.pendingCount == 1) // the port write is in flight, held

        clock.advance(by: 1)
        let nudgeWrite = Task { await writer.requestReconnect() }
        // The nudge's save must NOT join the in-flight set — it queues behind the chain. Give it
        // ample chances to (wrongly) start before asserting it never did.
        for _ in 0..<2_000 { await Task.yield() }
        #expect(await store.pendingCount == 1)

        await store.releaseAllReversed() // complete the port write; the nudge may start now
        for _ in 0..<10_000 where await store.pendingCount < 1 { await Task.yield() }
        #expect(await store.pendingCount == 1)
        await store.releaseAllReversed()
        _ = await portWrite.value
        _ = await nudgeWrite.value

        // Landing order == trigger order == epoch order: the record never regresses.
        let landed = await store.landed
        #expect(landed.count == 3)
        #expect(landed[1].port == 5001)
        #expect(landed[2].wantsReconnect == 1)
        #expect(landed.map(\.epoch) == landed.map(\.epoch).sorted())
        #expect(landed[2].epoch > landed[1].epoch)
    }

    // MARK: No-timer invariant

    /// Spec §1: NEVER write on a timer — every write costs the phone silent-push budget. With hosting
    /// "running" and hours of simulated wall clock passing, zero additional writes may appear; only
    /// an explicit trigger writes.
    @Test func noWritesWithoutATrigger() async throws {
        let (writer, store, clock) = makeWriter()
        await writer.hostingStarted(pinHex: "ab12cd", hostName: "Studio", port: 4242)
        #expect(await store.saveAttempts == 1)

        clock.advance(by: 6 * 3600) // six hours of hosting, no triggers
        // Short real grace so any stray internal task would have a chance to fire (negative check).
        try await Task.sleep(for: .milliseconds(100))
        #expect(await store.saveAttempts == 1)

        await writer.requestReconnect() // and the next explicit trigger still writes
        #expect(await store.saveAttempts == 2)
    }
}

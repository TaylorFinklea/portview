// SPDX-License-Identifier: Apache-2.0
import Foundation
import Network
import Testing

@testable import PortviewHostCore
@testable import PortviewTransport
import PortviewProtocol

/// `HostControl` registry + generation + revoke-lease-fence (han.4 Task 4, design §2/§3/§4/§7/§8).
///
/// These are pure registry-logic tests: they use **phantom** (never-started) `PortviewConnection`s so
/// the assertions are on the deterministic registry/generation/fence/keepAwake transitions, not on
/// QUIC close-propagation timing (which the loopback `HostControlEvictionTests` intentionally covers).
/// `beginRevoke`/`evictLegacyAdmitted` only `cancel()` the transport (no send), which is safe on an
/// unstarted `NWConnection`.
@Suite(.timeLimit(.minutes(1))) struct HostControlRegistryTests {

    // MARK: - Fixtures

    /// A `PortviewConnection` over an unstarted `NWConnection` — a valid registry value that never
    /// touches the network. `closeDiscardingInbound`/`cancel` are safe on it.
    private func phantomConnection() -> PortviewConnection {
        let nw = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)  // discard port; never started
        return PortviewConnection(connection: nw, queue: DispatchQueue(label: "test.phantom"))
    }

    private func lane(_ connection: PortviewConnection) -> OutboundLane<AnyMessage> {
        OutboundLane(connection: connection)
    }

    private func makeControl(_ backend: KeepAwakeBackend = NoopKeepAwakeBackend()) -> HostControl {
        HostControl(keepAwake: KeepAwake(backend: backend, ticker: NoopTicker()))
    }

    /// Register a keyed session under `keyID` at `generation` and return its capability. Fails the
    /// test if admission is rejected (the caller asserts admission separately when that's the point).
    @discardableResult
    private func admit(_ control: HostControl, id: SessionID, key: ClientKeyID,
                       generation: UInt64) -> (SessionCapability, PortviewConnection) {
        let capability = SessionCapability()
        let connection = phantomConnection()
        let result = control.register(id, connection, outbound: lane(connection), authClass: .authenticated,
                                      ticket: AdmissionTicket(keyID: key, generation: generation),
                                      capability: capability)
        #expect(result == .admitted)
        return (capability, connection)
    }

    // MARK: - registry + generation + begin/end (§8 first bullet)

    @Test func registerThreadsTicketAndCapability_byClientHoldsMultiplePerKey_beginRevokeKillsAll_endRevokeLifts() {
        let control = makeControl()
        let (capA, _) = admit(control, id: "A", key: "K", generation: 0)
        let (capB, _) = admit(control, id: "B", key: "K", generation: 0)

        // byClient is a SET: two sessions under one key are both indexed (invariant 8).
        #expect(control.sessionIDs(forClientKeyID: "K") == ["A", "B"])
        #expect(control.activeSessionIDs() == ["A", "B"])
        #expect(capA.isValid && capB.isValid)

        let receipt = control.beginRevoke(clientKeyID: "K")
        // One begin kills ALL of the key's live sessions and invalidates each capability.
        #expect(receipt.evictedCount == 2)
        #expect(capA.isValid == false)
        #expect(capB.isValid == false)
        #expect(control.activeSessionIDs().isEmpty)
        #expect(control.sessionIDs(forClientKeyID: "K").isEmpty)
        // Fenced: no ticket while revoking.
        #expect(control.admissionTicket(for: "K") == nil)

        control.endRevoke(lease: receipt.lease)
        // Fence lifted; generation stays bumped (0 → 1).
        let ticket = control.admissionTicket(for: "K")
        #expect(ticket?.keyID == "K")
        #expect(ticket?.generation == 1)
    }

    // MARK: - ticket-at-authorization (finding 1, §3 register-time table)

    @Test func ticketAtAuthorization_staleGenerationTicketRejectedAtRegister() {
        let control = makeControl()
        // t0: ticket captured at authorization reads gen 0; S1 registers.
        let t0 = control.admissionTicket(for: "K")
        #expect(t0?.generation == 0)
        admit(control, id: "S1", key: "K", generation: 0)

        // t1: revoke bumps gen 0 → 1, evicts S1. t2: durable revoke succeeds → endRevoke lifts the
        // fence (models "re-enroll makes isAuthorized true again" — the durable record may say yes,
        // but the generation is permanent).
        let receipt = control.beginRevoke(clientKeyID: "K")
        control.endRevoke(lease: receipt.lease)

        // t3: the session finally reaches register carrying the PRE-bump ticket (gen 0). The §3 table:
        // its admission predates the revoke, so register REJECTS it even though the fence is lifted and
        // the key is durably authorized again.
        let stale = SessionCapability()
        let staleConn = phantomConnection()
        let rejected = control.register("S1-late", staleConn, outbound: lane(staleConn), authClass: .authenticated,
                                        ticket: AdmissionTicket(keyID: "K", generation: 0), capability: stale)
        #expect(rejected == .rejected)
        #expect(control.activeSessionIDs().isEmpty)  // never admitted

        // A FRESH session that captured its ticket POST-bump (gen 1) IS admitted.
        let fresh = control.admissionTicket(for: "K")
        #expect(fresh?.generation == 1)
        admit(control, id: "S2", key: "K", generation: 1)
        #expect(control.activeSessionIDs() == ["S2"])
    }

    // MARK: - lease fence (finding 2, H-c)

    @Test func leaseFence_fencedKeyRejectsTicketAndRegister() {
        let control = makeControl()
        let receipt = control.beginRevoke(clientKeyID: "K")
        // While K ∈ revoking: admissionTicket nil, and register rejects even a "current-generation"
        // ticket (the fence dominates the generation check).
        #expect(control.admissionTicket(for: "K") == nil)
        let cap = SessionCapability()
        let conn = phantomConnection()
        let result = control.register("X", conn, outbound: lane(conn), authClass: .authenticated,
                                      ticket: AdmissionTicket(keyID: "K", generation: 1), capability: cap)
        #expect(result == .rejected)
        control.endRevoke(lease: receipt.lease)  // cleanup
    }

    @Test func leaseFence_duplicateBeginCoalesces_noSecondFenceOrBump() {
        let control = makeControl()
        admit(control, id: "S1", key: "K", generation: 0)

        let first = control.beginRevoke(clientKeyID: "K")
        #expect(first.evictedCount == 1)
        // A second begin coalesces: same owning lease, evicts nothing new, does not bump again.
        let second = control.beginRevoke(clientKeyID: "K")
        #expect(second.lease == first.lease)
        #expect(second.evictedCount == 0)

        control.endRevoke(lease: first.lease)
        // Generation bumped exactly once (0 → 1), not twice.
        #expect(control.admissionTicket(for: "K")?.generation == 1)
    }

    @Test func leaseFence_staleLeaseEndIsNoop_matchingLeaseLifts() {
        let control = makeControl()
        let firstReceipt = control.beginRevoke(clientKeyID: "K")
        control.endRevoke(lease: firstReceipt.lease)               // lifts
        #expect(control.admissionTicket(for: "K") != nil)

        // A second, independent revoke of K mints a NEW lease.
        let secondReceipt = control.beginRevoke(clientKeyID: "K")
        #expect(secondReceipt.lease != firstReceipt.lease)
        // The STALE (first) lease must NOT lift the second op's fence.
        control.endRevoke(lease: firstReceipt.lease)
        #expect(control.admissionTicket(for: "K") == nil)          // still fenced
        // The MATCHING lease lifts.
        control.endRevoke(lease: secondReceipt.lease)
        #expect(control.admissionTicket(for: "K") != nil)
        #expect(control.admissionTicket(for: "K")?.generation == 2) // two bumps
    }

    @Test func leaseFence_failClosed_durableThrowRetainsFence_retryOrCancelLifts() {
        // Fail-closed (H-c): on a durable-revoke failure the orchestrator does NOT call endRevoke, so
        // the fence STAYS — K is unauthorizable. HostControl's contract is that the fence persists
        // until a MATCHING end/cancel, which is exactly what makes fail-closed possible.
        let control = makeControl()

        // Scenario 1: durable throw → (no endRevoke) → fence retained → Retry succeeds → endRevoke lifts.
        let r1 = control.beginRevoke(clientKeyID: "K")
        // (simulated durable throw here — nothing called)
        #expect(control.admissionTicket(for: "K") == nil)          // fence retained, K unauthorizable
        // Retry's durable revoke succeeds under the SAME lease → endRevoke lifts.
        control.endRevoke(lease: r1.lease)
        #expect(control.admissionTicket(for: "K") != nil)

        // Scenario 2: durable throw → authenticated Cancel lifts WITHOUT a durable revoke.
        let r2 = control.beginRevoke(clientKeyID: "K2")
        #expect(control.admissionTicket(for: "K2") == nil)         // fence retained
        control.cancelRevoke(lease: r2.lease)
        #expect(control.admissionTicket(for: "K2") != nil)         // re-admittable (still-enrolled key)
    }

    // MARK: - Invalidate-First (H-d) & nil-key legacy independence

    @Test func invalidateFirst_deregisterIsBookkeepingOnly_doesNotInvalidate() {
        let control = makeControl()
        let (cap, _) = admit(control, id: "S1", key: "K", generation: 0)
        control.deregister("S1")
        // deregister is registry bookkeeping ONLY — the caller invalidates first, so deregister must
        // NOT flip the capability (Invalidate-First is the caller's job on this path).
        #expect(cap.isValid == true)
        #expect(control.activeSessionIDs().isEmpty)
        #expect(control.sessionIDs(forClientKeyID: "K").isEmpty)
    }

    @Test func invalidateFirst_evictLegacyInvalidatesCapability_keepsAuthenticated() {
        let control = makeControl()
        // Legacy session: nil-key ticket.
        let legacyCap = SessionCapability()
        let legacyConn = phantomConnection()
        control.register("legacy", legacyConn, outbound: lane(legacyConn), authClass: .legacyAdmitted,
                         ticket: AdmissionTicket(keyID: nil, generation: 0), capability: legacyCap)
        let (authedCap, _) = admit(control, id: "authed", key: "K", generation: 0)

        control.evictLegacyAdmitted()
        #expect(legacyCap.isValid == false)   // legacy capability invalidated
        #expect(authedCap.isValid == true)    // authenticated untouched
        #expect(control.activeSessionIDs() == ["authed"])
    }

    @Test func invalidateFirst_disconnectAllInvalidatesSynchronouslyBeforeAsyncClose() {
        let control = makeControl()
        let (capA, _) = admit(control, id: "A", key: "K", generation: 0)
        let legacyCap = SessionCapability()
        let legacyConn = phantomConnection()
        control.register("legacy", legacyConn, outbound: lane(legacyConn), authClass: .legacyAdmitted,
                         ticket: AdmissionTicket(keyID: nil, generation: 0), capability: legacyCap)

        control.disconnectAll()
        // invalidate() is synchronous and runs BEFORE the async bye/close Task — so both capabilities
        // are already invalid the instant disconnectAll returns (proof invalidate precedes teardown).
        #expect(capA.isValid == false)
        #expect(legacyCap.isValid == false)
        // Clears byClient AND sessions (M-a/finding 8a).
        #expect(control.activeSessionIDs().isEmpty)
        #expect(control.sessionIDs(forClientKeyID: "K").isEmpty)
    }

    @Test func beginRevokeInvalidatesAllUnderKey() {
        let control = makeControl()
        let (capA, _) = admit(control, id: "A", key: "K", generation: 0)
        let (capB, _) = admit(control, id: "B", key: "K", generation: 0)
        _ = control.beginRevoke(clientKeyID: "K")
        #expect(capA.isValid == false)
        #expect(capB.isValid == false)
    }

    @Test func deregisterBySessionIDDoesNotWipeReconnectingSibling() {
        let control = makeControl()
        admit(control, id: "S1", key: "K", generation: 0)
        admit(control, id: "S2", key: "K", generation: 0)
        control.deregister("S1")
        // Precisely S1 removed; the sibling S2 under the same key survives.
        #expect(control.activeSessionIDs() == ["S2"])
        #expect(control.sessionIDs(forClientKeyID: "K") == ["S2"])
    }

    @Test func beginRevokeIgnoresNilKeyLegacySessions() {
        let control = makeControl()
        let legacyCap = SessionCapability()
        let legacyConn = phantomConnection()
        control.register("legacy", legacyConn, outbound: lane(legacyConn), authClass: .legacyAdmitted,
                         ticket: AdmissionTicket(keyID: nil, generation: 0), capability: legacyCap)
        let (keyedCap, _) = admit(control, id: "keyed", key: "K", generation: 0)

        _ = control.beginRevoke(clientKeyID: "K")
        // Revoke is key-scoped: the keyed session dies, the nil-key legacy session is untouched
        // (invariant 11).
        #expect(keyedCap.isValid == false)
        #expect(legacyCap.isValid == true)
        #expect(control.activeSessionIDs() == ["legacy"])
    }

    @Test func beginRevokeWithNoLiveSessionsStillFencesAndBumps() {
        let control = makeControl()
        #expect(control.admissionTicket(for: "K")?.generation == 0)
        let receipt = control.beginRevoke(clientKeyID: "K")
        #expect(receipt.evictedCount == 0)
        #expect(control.admissionTicket(for: "K") == nil)   // fenced even with no live sessions
        control.endRevoke(lease: receipt.lease)
        #expect(control.admissionTicket(for: "K")?.generation == 1)  // still bumped
    }

    // MARK: - keepAwake linearization (finding 8b, M-a)

    /// A `disconnectAll` `endAll` racing a `register`'s `sessionBegan` must NOT interleave into
    /// register's in-lock critical section — otherwise it could release the newly-registering id's
    /// assertion. The fix moves `sessionBegan`/`endAll` INSIDE the HostControl lock; this barrier
    /// proves it by parking register mid-`beginPreventingSleep` (still holding the HostControl lock)
    /// and showing `disconnectAll` cannot make progress (no `endPreventingSleep`) until register
    /// releases the lock. Balance is asserted at the end.
    @Test func keepAwakeLinearization_disconnectAllRacingRegisterCannotInterleave() {
        let backend = BarrierKeepAwakeBackend()
        let control = makeControl(backend)
        let cap = SessionCapability()
        let conn = phantomConnection()

        let registerDone = DispatchSemaphore(value: 0)
        let disconnectDone = DispatchSemaphore(value: 0)

        // Thread A: register — its sessionBegan → startLocked → beginPreventingSleep PARKS while
        // holding the HostControl lock.
        Thread.detachNewThread {
            _ = control.register("new", conn, outbound: OutboundLane(connection: conn), authClass: .authenticated,
                                 ticket: AdmissionTicket(keyID: nil, generation: 0), capability: cap)
            registerDone.signal()
        }
        // Wait until register is parked inside beginPreventingSleep (holding the lock).
        #expect(backend.beganEntered.wait(timeout: .now() + 10) == .success)

        // Thread B: disconnectAll — blocks on the HostControl lock register still holds.
        Thread.detachNewThread {
            control.disconnectAll()
            disconnectDone.signal()
        }

        // While register is parked mid-sessionBegan, endAll MUST NOT have run: proof that the two are
        // serialized by the HostControl lock and endAll can't release the new id's assertion.
        Thread.sleep(forTimeInterval: 0.05)
        #expect(backend.endCount == 0)
        #expect(disconnectDone.wait(timeout: .now() + 0.01) == .timedOut)

        // Release the barrier; register completes, then disconnectAll proceeds.
        backend.releaseBegin.signal()
        #expect(registerDone.wait(timeout: .now() + 10) == .success)
        #expect(disconnectDone.wait(timeout: .now() + 10) == .success)

        // Balanced: exactly one begin, one end, nothing held, no double begin/end.
        #expect(backend.beginCount == 1)
        #expect(backend.endCount == 1)
        #expect(backend.held == false)
        #expect(backend.doubledUp == false)
    }
}

// MARK: - Test backends / tickers

/// A keep-awake backend that does nothing (tests must not touch the live IOPM assertion surface).
private final class NoopKeepAwakeBackend: KeepAwakeBackend, @unchecked Sendable {
    func beginPreventingSleep() {}
    func endPreventingSleep() {}
    func declareUserActivity() {}
}

/// A ticker that never fires (no wall-clock timer → deterministic under parallel load).
private final class NoopTicker: KeepAwakeTicker, @unchecked Sendable {
    func start(interval: TimeInterval, onFire: @escaping @Sendable () -> Void) {}
    func stop() {}
}

/// Records begin/end balance and lets a test PARK inside `beginPreventingSleep` (via `releaseBegin`)
/// to hold the caller's lock open for a barrier race. Flags a double-begin (begin while held) or
/// double-end (end while not held).
private final class BarrierKeepAwakeBackend: KeepAwakeBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _held = false
    private var _beginCount = 0
    private var _endCount = 0
    private var _doubledUp = false
    let beganEntered = DispatchSemaphore(value: 0)
    let releaseBegin = DispatchSemaphore(value: 0)

    var held: Bool { lock.lock(); defer { lock.unlock() }; return _held }
    var beginCount: Int { lock.lock(); defer { lock.unlock() }; return _beginCount }
    var endCount: Int { lock.lock(); defer { lock.unlock() }; return _endCount }
    var doubledUp: Bool { lock.lock(); defer { lock.unlock() }; return _doubledUp }

    func beginPreventingSleep() {
        lock.lock()
        if _held { _doubledUp = true }
        _held = true
        _beginCount += 1
        lock.unlock()
        beganEntered.signal()
        releaseBegin.wait()   // park while the caller still holds its lock (barrier)
    }

    func endPreventingSleep() {
        lock.lock()
        if !_held { _doubledUp = true }
        _held = false
        _endCount += 1
        lock.unlock()
    }

    func declareUserActivity() {}
}

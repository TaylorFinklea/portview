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
        OutboundLane(connection: connection, capability: SessionCapability())
    }

    private func makeControl(_ backend: KeepAwakeBackend = NoopKeepAwakeBackend()) -> HostControl {
        HostControl(keepAwake: KeepAwake(backend: backend, ticker: NoopTicker()))
    }

    /// Watch `capability.isValid` from a DEDICATED thread and signal once it goes false, so the test
    /// thread never blocks on the capability itself: before the mark/drain split the flag getter took
    /// the very lock a parked `perform` holds, so a direct read would HANG the test rather than fail
    /// it. The observer thread exits as soon as the parked effect is released.
    private func observeInvalidation(of capability: SessionCapability) -> DispatchSemaphore {
        let observed = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            while capability.isValid { Thread.sleep(forTimeInterval: 0.002) }
            observed.signal()
        }
        return observed
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

    /// Final-review M-3 (design §10 R8): with 2+ live sessions under ONE key, `beginRevoke` must
    /// invalidate **every** snapshotted capability BEFORE it starts tearing down any of their
    /// transports. The old per-session `invalidate → finish → close` interleave left the LATER
    /// session's capability valid for the whole of the EARLIER session's transport teardown —
    /// strictly wider than R8's documented "≤ one irreducible effect per capability" bound.
    ///
    /// Witness: each session's outbound lane drains into an injected sink that PARKS inside a
    /// `withTaskCancellationHandler`. `OutboundLane.finish()` — the first step of a session's
    /// transport teardown — cancels that drain task, and `Task.cancel()` runs the registered
    /// cancellation handler synchronously on `beginRevoke`'s own thread, so the handler samples both
    /// capabilities at the exact instant the first teardown becomes observable.
    @Test func beginRevoke_invalidatesEveryCapabilityBeforeAnyTransportTeardown() async throws {
        let control = makeControl()
        let capA = SessionCapability()
        let capB = SessionCapability()
        let witness = TeardownWitness()
        let sinkA = ParkedSink { witness.record(a: capA.isValid, b: capB.isValid) }
        let sinkB = ParkedSink { witness.record(a: capA.isValid, b: capB.isValid) }
        let connA = phantomConnection()
        let connB = phantomConnection()
        let laneA = OutboundLane<AnyMessage>(sink: { _ in await sinkA.park() })
        let laneB = OutboundLane<AnyMessage>(sink: { _ in await sinkB.park() })

        #expect(control.register("A", connA, outbound: laneA, authClass: .authenticated,
                                 ticket: AdmissionTicket(keyID: "K", generation: 0),
                                 capability: capA) == .admitted)
        #expect(control.register("B", connB, outbound: laneB, authClass: .authenticated,
                                 ticket: AdmissionTicket(keyID: "K", generation: 0),
                                 capability: capB) == .admitted)

        // Drive each drain task into its sink so the cancellation handlers are registered.
        laneA.enqueue(.ping(Ping(sendMicros: 1)))
        laneB.enqueue(.ping(Ping(sendMicros: 2)))
        let deadline = Date().addingTimeInterval(10)
        while !(sinkA.isParked && sinkB.isParked), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(sinkA.isParked && sinkB.isParked)

        _ = control.beginRevoke(clientKeyID: "K")

        let samples = witness.samples
        #expect(samples.count == 2)  // both teardowns observed, synchronously inside beginRevoke
        // At EVERY teardown instant — including the FIRST — no capability under the key is still live.
        #expect(samples.allSatisfy { !$0.a && !$0.b })
    }

    /// Sol review C1 (second half): `evictLegacyAdmitted` never got `beginRevoke`'s multi-pass
    /// treatment — it ran `invalidate → finish → close` per session, so the LAST legacy session kept
    /// full authority for the whole of the FIRST one's transport teardown. Same `ParkedSink` witness
    /// as `beginRevoke_invalidatesEveryCapabilityBeforeAnyTransportTeardown`.
    @Test func evictLegacyAdmitted_invalidatesEveryCapabilityBeforeAnyTransportTeardown() async throws {
        let control = makeControl()
        let capA = SessionCapability()
        let capB = SessionCapability()
        let witness = TeardownWitness()
        let sinkA = ParkedSink { witness.record(a: capA.isValid, b: capB.isValid) }
        let sinkB = ParkedSink { witness.record(a: capA.isValid, b: capB.isValid) }
        let connA = phantomConnection()
        let connB = phantomConnection()
        let laneA = OutboundLane<AnyMessage>(sink: { _ in await sinkA.park() })
        let laneB = OutboundLane<AnyMessage>(sink: { _ in await sinkB.park() })

        #expect(control.register("A", connA, outbound: laneA, authClass: .legacyAdmitted,
                                 ticket: AdmissionTicket(keyID: nil, generation: 0),
                                 capability: capA) == .admitted)
        #expect(control.register("B", connB, outbound: laneB, authClass: .legacyAdmitted,
                                 ticket: AdmissionTicket(keyID: nil, generation: 0),
                                 capability: capB) == .admitted)

        laneA.enqueue(.ping(Ping(sendMicros: 1)))
        laneB.enqueue(.ping(Ping(sendMicros: 2)))
        let deadline = Date().addingTimeInterval(10)
        while !(sinkA.isParked && sinkB.isParked), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(sinkA.isParked && sinkB.isParked)

        control.evictLegacyAdmitted()

        let samples = witness.samples
        #expect(samples.count == 2)
        #expect(samples.allSatisfy { !$0.a && !$0.b })
    }

    /// Sol review C1 (design §10 R8): the previous regression test parked OUTBOUND teardown, which
    /// never exercised the actual counterexample — a session parked INSIDE `capability.perform`.
    /// `invalidate()` used to take the SAME lock `perform` holds for the whole effect, so the
    /// teardown blocked on the first session whose effect was in flight (a stalled
    /// `FileHandle.write`) and **every later session under the key stayed valid, with its inbound
    /// still open, for the entire stall** — a revoked device kept full keyboard/pointer/clipboard/
    /// file control through its second session. R8's "≤ one irreducible effect per capability" did
    /// not hold. The mark/drain split fixes it: the non-blocking MARK pass lands on every
    /// snapshotted capability before the blocking DRAIN pass waits out any in-flight effect.
    ///
    /// Both sessions park inside an effect so the assertion is independent of `byClient`'s
    /// (hash-seeded, per-process) set iteration order — pre-fix, NEITHER capability can be flipped
    /// while both effects are in flight, whichever the teardown reaches first.
    @Test func beginRevoke_marksEverySiblingInvalidWhileASessionIsParkedInsidePerform() {
        let control = makeControl()
        let (capA, _) = admit(control, id: "A", key: "K", generation: 0)
        let (capB, _) = admit(control, id: "B", key: "K", generation: 0)

        let enteredA = DispatchSemaphore(value: 0), releaseA = DispatchSemaphore(value: 0)
        let enteredB = DispatchSemaphore(value: 0), releaseB = DispatchSemaphore(value: 0)
        Thread.detachNewThread { capA.perform { enteredA.signal(); releaseA.wait() } }
        Thread.detachNewThread { capB.perform { enteredB.signal(); releaseB.wait() } }
        #expect(enteredA.wait(timeout: .now() + 10) == .success)
        #expect(enteredB.wait(timeout: .now() + 10) == .success)

        let markedA = observeInvalidation(of: capA)
        let markedB = observeInvalidation(of: capB)
        let revokeReturned = DispatchSemaphore(value: 0)
        Thread.detachNewThread { _ = control.beginRevoke(clientKeyID: "K"); revokeReturned.signal() }

        // Pass 0 (MARK) is non-blocking, so BOTH capabilities lose authority while BOTH effects are
        // still in flight.
        #expect(markedA.wait(timeout: .now() + 5) == .success)
        #expect(markedB.wait(timeout: .now() + 5) == .success)
        // …and the DRAIN pass is genuinely still waiting on those in-flight effects (so this is a
        // real stall, not a teardown that already finished).
        #expect(revokeReturned.wait(timeout: .now() + 0.05) == .timedOut)

        // The decisive counterexample: release ONLY B. With A still parked mid-effect, B must be
        // unable to START a new effect.
        releaseB.signal()
        var ranB = false
        #expect(capB.perform { ranB = true } == false)
        #expect(ranB == false)
        #expect(revokeReturned.wait(timeout: .now() + 0.05) == .timedOut)

        // Releasing A completes the drain; the teardown then finishes normally.
        releaseA.signal()
        #expect(revokeReturned.wait(timeout: .now() + 10) == .success)
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
            _ = control.register("new", conn, outbound: OutboundLane(connection: conn, capability: cap), authClass: .authenticated,
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

/// Records what every observed transport teardown saw of the two capabilities under the key.
private final class TeardownWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(a: Bool, b: Bool)] = []
    func record(a: Bool, b: Bool) { lock.lock(); recorded.append((a, b)); lock.unlock() }
    var samples: [(a: Bool, b: Bool)] { lock.lock(); defer { lock.unlock() }; return recorded }
}

/// An `OutboundLane` sink that parks its drain task forever under a cancellation handler. Because
/// `OutboundLane.finish()` cancels the drain task and `Task.cancel()` runs cancellation handlers
/// synchronously on the cancelling thread, `onTeardown` fires inline at the first observable moment
/// of that lane's teardown.
private final class ParkedSink: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var parked = false
    private var released = false
    private let onTeardown: @Sendable () -> Void

    init(_ onTeardown: @escaping @Sendable () -> Void) { self.onTeardown = onTeardown }

    var isParked: Bool { lock.lock(); defer { lock.unlock() }; return parked }

    func park() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                guard !released else { lock.unlock(); continuation.resume(); return }
                self.continuation = continuation
                parked = true
                lock.unlock()
            }
        } onCancel: {
            onTeardown()
            lock.lock()
            let pending = continuation
            continuation = nil
            released = true
            lock.unlock()
            pending?.resume()
        }
    }
}

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

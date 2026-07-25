// SPDX-License-Identifier: Apache-2.0
import Foundation
import Network
import Testing

@testable import PortviewHostCore
@testable import PortviewTransport
import PortviewProtocol

/// `serveSession`'s admission spine (han.4 Task 8, design §1b step 6 / §5, findings 5 + H-e), driven
/// directly through the `HostRunner.admitSession` seam that the reorder factors out. `admitSession`
/// is exactly the register → post-await durable recheck → Invalidate-First teardown that now runs
/// AHEAD of every producer and of `ServerHello`, so these prove the ordering invariant without needing
/// a live display (the full loopback closes at the display guard, which sits BEFORE admission by
/// design). Pure registry-logic tests over **phantom** connections (mirroring `HostControlRegistryTests`).
@Suite(.timeLimit(.minutes(1))) struct AdmissionOrderingTests {

    /// A `PortviewConnection` over an unstarted `NWConnection` — a valid registry value that never
    /// touches the network. `closeDiscardingInbound`/`cancel` are safe on it.
    private func phantomConnection() -> PortviewConnection {
        let nw = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)  // discard port; never started
        return PortviewConnection(connection: nw, queue: DispatchQueue(label: "test.admit.phantom"))
    }

    private func lane(_ connection: PortviewConnection, _ capability: SessionCapability) -> OutboundLane<AnyMessage> {
        OutboundLane(connection: connection, capability: capability)
    }

    private func makeControl() -> HostControl {
        HostControl(keepAwake: KeepAwake(backend: AdmitNoopKeepAwakeBackend(), ticker: AdmitNoopTicker()))
    }

    // MARK: - admitSession happy path

    @Test func admitSession_happyPath_registersAndReturnsTrue() async {
        let control = makeControl()
        let capability = SessionCapability()
        let connection = phantomConnection()
        let ticket = control.admissionTicket(for: "K")!  // captured at authorization: (K, 0)

        let admitted = await HostRunner.admitSession(
            connection, control: control, outbound: lane(connection, capability), capability: capability,
            authClass: .authenticated, ticket: ticket, sessionID: "S1", isAuthorized: { _ in true })

        #expect(admitted)
        #expect(capability.isValid)
        #expect(control.activeSessionIDs() == ["S1"])
        #expect(control.sessionIDs(forClientKeyID: "K") == ["S1"])
    }

    @Test func admitSession_legacyNilKeyTicketSkipsDurableRecheck() async {
        let control = makeControl()
        let capability = SessionCapability()
        let connection = phantomConnection()

        let admitted = await HostRunner.admitSession(
            connection, control: control, outbound: lane(connection, capability), capability: capability,
            authClass: .legacyAdmitted, ticket: AdmissionTicket(keyID: nil, generation: 0), sessionID: "L1",
            isAuthorized: { _ in
                Issue.record("a legacy nil-key ticket must skip the durable isAuthorized recheck")
                return false
            })

        #expect(admitted)
        #expect(control.activeSessionIDs() == ["L1"])
    }

    // MARK: - revoke between gate-authorize and register (design §5, finding 5)

    @Test func admitSession_revokeBeforeRegister_selfClosesAtFence_neverAdmitted() async {
        // The ticket is captured at authorization (gen 0). A revoke then lands BEFORE register — the
        // key is now fenced, so register REJECTS and admitSession self-closes Invalidate-First. No
        // producer runs and no ServerHello is sent (there is no send path before the reject).
        let control = makeControl()
        let ticket = control.admissionTicket(for: "K")!  // (K, 0), pre-revoke
        _ = control.beginRevoke(clientKeyID: "K")         // revoke lands in the gate→register gap

        let capability = SessionCapability()
        let connection = phantomConnection()
        let admitted = await HostRunner.admitSession(
            connection, control: control, outbound: lane(connection, capability), capability: capability,
            authClass: .authenticated, ticket: ticket, sessionID: "S1", isAuthorized: { _ in
                Issue.record("the durable recheck must NOT run once register has already rejected")
                return true
            })

        #expect(admitted == false)
        #expect(capability.isValid == false)             // Invalidate-First (H-d)
        #expect(control.activeSessionIDs().isEmpty)       // never admitted
    }

    @Test func admitSession_staleGenerationTicketRejected() async {
        // Order-A (finding 1): a ticket carrying the PRE-bump generation is rejected at register even
        // after the fence lifts and the key is durably authorized again (a revoke→re-enroll straddle).
        let control = makeControl()
        let staleTicket = control.admissionTicket(for: "K")!  // gen 0
        let receipt = control.beginRevoke(clientKeyID: "K")   // bump → gen 1
        control.endRevoke(lease: receipt.lease)               // fence lifted; gen stays 1

        let capability = SessionCapability()
        let connection = phantomConnection()
        let admitted = await HostRunner.admitSession(
            connection, control: control, outbound: lane(connection, capability), capability: capability,
            authClass: .authenticated, ticket: staleTicket, sessionID: "S1-late", isAuthorized: { _ in true })

        #expect(admitted == false)
        #expect(capability.isValid == false)
        #expect(control.activeSessionIDs().isEmpty)
    }

    // MARK: - revoke DURING the durable await (design §5, H-e — the post-await recheck)

    @Test func admitSession_revokeDuringDurableAwait_selfClosesAtPostAwaitRecheck() async {
        // register succeeds (fence not yet set). The durable await then SUSPENDS; during it the injected
        // `isAuthorized` lands the revoke — which invalidates THIS session's capability synchronously —
        // and returns stale-true. The post-await `capability.isValid` recheck must STILL catch it (H-e).
        let control = makeControl()
        let ticket = control.admissionTicket(for: "K")!  // (K, 0)
        let capability = SessionCapability()
        let connection = phantomConnection()

        let admitted = await HostRunner.admitSession(
            connection, control: control, outbound: lane(connection, capability), capability: capability,
            authClass: .authenticated, ticket: ticket, sessionID: "S1", isAuthorized: { key in
                // The revoke lands mid-await: beginRevoke invalidates the just-registered capability
                // and evicts the session. The durable read still returns TRUE (stale) on purpose.
                _ = control.beginRevoke(clientKeyID: key)
                return true
            })

        #expect(admitted == false)
        #expect(capability.isValid == false)
        #expect(control.activeSessionIDs().isEmpty)  // evicted by the revoke, deregistered by the recheck
    }

    @Test func admitSession_durableNoLongerAuthorized_selfCloses() async {
        // The durable backstop alone: a keyed session whose durable `isAuthorized` returns false (a
        // revoke fully completed before this session registered) self-closes even with a valid capability.
        let control = makeControl()
        let ticket = control.admissionTicket(for: "K")!
        let capability = SessionCapability()
        let connection = phantomConnection()

        let admitted = await HostRunner.admitSession(
            connection, control: control, outbound: lane(connection, capability), capability: capability,
            authClass: .authenticated, ticket: ticket, sessionID: "S1", isAuthorized: { _ in false })

        #expect(admitted == false)
        #expect(capability.isValid == false)
        #expect(control.activeSessionIDs().isEmpty)
    }

    // MARK: - CLI control minting (M-b)

    @Test func resolvedControl_nilMintsAFreshProcessLocalControl() {
        // The CLI (`run(control: nil)`) gets ONE minted registry; each mint is a distinct instance.
        let a = HostRunner.resolvedControl(nil)
        let b = HostRunner.resolvedControl(nil)
        #expect(a !== b)
        // The minted control is a working registry: it fences/bumps like any other.
        #expect(a.admissionTicket(for: "K")?.generation == 0)
        let receipt = a.beginRevoke(clientKeyID: "K")
        #expect(a.admissionTicket(for: "K") == nil)  // fenced
        a.endRevoke(lease: receipt.lease)
        #expect(a.admissionTicket(for: "K")?.generation == 1)
    }

    @Test func resolvedControl_passesThroughAnExistingControl() {
        // The app supplies its own control (it owns the revoke UI) — resolvedControl must not replace it.
        let existing = makeControl()
        #expect(HostRunner.resolvedControl(existing) === existing)
    }
}

/// A keep-awake backend that does nothing (tests must not touch the live IOPM assertion surface).
private final class AdmitNoopKeepAwakeBackend: KeepAwakeBackend, @unchecked Sendable {
    func beginPreventingSleep() {}
    func endPreventingSleep() {}
    func declareUserActivity() {}
}

/// A ticker that never fires (no wall-clock timer → deterministic under parallel load).
private final class AdmitNoopTicker: KeepAwakeTicker, @unchecked Sendable {
    func start(interval: TimeInterval, onFire: @escaping @Sendable () -> Void) {}
    func stop() {}
}

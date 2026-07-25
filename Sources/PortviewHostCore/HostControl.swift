// SPDX-License-Identifier: Apache-2.0
import Foundation
import PortviewProtocol
import PortviewTransport

/// A thread-safe registry of active client connections so the host UI can disconnect them without
/// tearing down the listener (which would otherwise churn the bound port and break saved pairings).
public final class HostControl: @unchecked Sendable {
    /// How a live session cleared the mutual-auth gate. Legacy-admitted sessions (bootstrap policy,
    /// no device key proven) must be terminable when the policy tightens to `.required`.
    public enum SessionAuthClass: Sendable {
        case authenticated
        case legacyAdmitted
    }

    private struct Session {
        let connection: PortviewConnection
        /// The session's ordered outbound lane (owned by its serve loop): broadcast/file sends
        /// enqueue here so they order with the session's other outbound traffic and stop at its
        /// teardown, instead of racing as detached per-send Tasks.
        let outbound: OutboundLane<AnyMessage>
        let authClass: SessionAuthClass
        /// The client key this session authenticated under, or `nil` for a legacy bootstrap-admitted
        /// session (no device key proven). Revoke is key-scoped; legacy sessions are key-independent.
        let keyID: ClientKeyID?
        /// The per-key generation captured in the session's admission ticket (design §3). Recorded
        /// for provenance; revoke targets a key's sessions by `byClient` membership, not by re-reading
        /// this — every live session under a key is, by construction, admitted at generation ≤ current.
        let admittedGeneration: UInt64
        /// The per-session act-permission capability, invalidated **first** on every terminal path
        /// (Invalidate-First, design §4/H-d) so no deferred or in-flight effect outlives the session.
        let capability: SessionCapability
    }

    private let lock = NSLock()
    private var sessions: [SessionID: Session] = [:]
    /// Live sessions indexed by client key — a **set** (never a single slot), so two concurrent or
    /// reconnecting sessions under one key are both indexed and one revoke finds all of them (design
    /// §2, invariant 8). Legacy (nil-key) sessions are absent here.
    private var byClient: [ClientKeyID: Set<SessionID>] = [:]
    /// Per-key monotonic generation (design §3). Bumped by `beginRevoke`; never reset by
    /// re-enrollment. `admittedGen < currentGen ⇒ the session predates a revoke ⇒ dead`.
    private var generation: [ClientKeyID: UInt64] = [:]
    /// The revoke fence (design §4/H-c): while a key maps to a lease, `admissionTicket`/`register`
    /// for that key are rejected. A map (not a set) so the lease can be required to lift it.
    private var revoking: [ClientKeyID: RevokeLease] = [:]
    /// Monotonic lease minter — a fresh, globally-unique id per `beginRevoke`, so a superseded
    /// operation's lease can never match a later fence for the same key.
    private var nextLeaseID: UInt64 = 0
    /// Holds a system keep-awake assertion while >=1 client is connected, so the Mac doesn't idle-sleep
    /// or idle-lock mid-session. Keyed by session id (see KeepAwake) so it survives `disconnectAll`.
    private let keepAwake: KeepAwake

    public init() {
        self.keepAwake = KeepAwake(backend: IOKitKeepAwakeBackend())
    }

    /// Test seam: inject a fake keep-awake backend.
    init(keepAwake: KeepAwake) {
        self.keepAwake = keepAwake
    }

    /// Snapshot the admission ticket for a key at the authorization instant (design §3, Order-A):
    /// `nil` iff the key is fenced (mid-revoke), else `(keyID, currentGeneration)`. Pure read —
    /// reserves no held resource. Captured inside `serveAuthGate` immediately after signature verify
    /// and carried by-value into `register`, so the ticket reflects authorization, not register.
    func admissionTicket(for keyID: ClientKeyID) -> AdmissionTicket? {
        lock.lock(); defer { lock.unlock() }
        guard revoking[keyID] == nil else { return nil }
        return AdmissionTicket(keyID: keyID, generation: generation[keyID] ?? 0)
    }

    /// Admit a session under a previously-captured ticket. For a keyed ticket the fence + generation
    /// check is the synchronous admission gate (design §3/§5): reject if the key is mid-revoke OR if
    /// the ticket's generation no longer matches the current one (its admission predates a bump). The
    /// check does NOT re-stamp the current generation — re-stamping at register was v1's finding-1 bug.
    /// Legacy tickets (`keyID == nil`) skip the fence/generation check. `keepAwake.sessionBegan` runs
    /// **inside the lock** so it strictly precedes any `sessionEnded`/`endAll` for this id (finding 8b).
    @discardableResult
    func register(_ id: SessionID, _ connection: PortviewConnection, outbound: OutboundLane<AnyMessage>,
                  authClass: SessionAuthClass, ticket: AdmissionTicket,
                  capability: SessionCapability) -> AdmissionResult {
        lock.lock()
        if let keyID = ticket.keyID {
            guard revoking[keyID] == nil && ticket.generation == (generation[keyID] ?? 0) else {
                lock.unlock()
                return .rejected
            }
            byClient[keyID, default: []].insert(id)
        }
        sessions[id] = Session(connection: connection, outbound: outbound, authClass: authClass,
                               keyID: ticket.keyID, admittedGeneration: ticket.generation,
                               capability: capability)
        keepAwake.sessionBegan(id)  // INSIDE the lock (finding 8b / invariant 13)
        lock.unlock()
        return .admitted
    }

    /// Registry bookkeeping only (design §2): remove the session precisely by SessionID — never
    /// wiping a reconnecting sibling under the same key — drop the key from `byClient` when its set
    /// empties, and `keepAwake.sessionEnded` **inside the lock**. Does **NOT** invalidate the
    /// capability: the *caller's* teardown already invalidated first (Invalidate-First, H-d). A
    /// no-op for an id a batch path (revoke/disconnect/evict) already removed — so no double
    /// `sessionEnded`.
    func deregister(_ id: SessionID) {
        lock.lock()
        if let session = sessions.removeValue(forKey: id) {
            if let keyID = session.keyID {
                byClient[keyID]?.remove(id)
                if byClient[keyID]?.isEmpty == true { byClient[keyID] = nil }
            }
            keepAwake.sessionEnded(id)  // INSIDE the lock (invariant 13)
        }
        lock.unlock()
    }

    /// Emergency capability withdrawal for a key (design §1a step 3 / §4). Under the lock, in order
    /// (nothing that can *wait* runs here — H-b): coalesce a duplicate begin (return the existing
    /// lease, no second fence/bump); else mint a fresh lease, set the fence, bump the generation,
    /// **snapshot** every live session under the key, unlink each from `sessions`/`byClient`, and
    /// `keepAwake.sessionEnded` each. Then **out of the lock**, in THREE passes: pass 0
    /// `capability.markInvalid()` on **every** snapshot (NON-blocking, so no session under the key
    /// can start a new effect even if a sibling's effect is stalled), pass 1
    /// `capability.drainInFlightEffect()` on each (the only bounded wait — ≤ one already-in-flight
    /// irreducible effect apiece), pass 2 `outbound.finish()` then
    /// `connection.closeDiscardingInbound()` on each (discard-not-drain, **no** graceful `bye` — a
    /// de-trusted peer loses access at once). Separate passes rather than one interleaved loop so a
    /// second session under the same key cannot keep acting while a sibling stalls or while a
    /// sibling's transport is torn down. The fence stays set (blocking new
    /// admission for the key) for the whole operation; it is lifted only by a matching
    /// `endRevoke`/`cancelRevoke`. Teardown is internal — the private `Session`/`OutboundLane` never
    /// escape (M-b).
    public func beginRevoke(clientKeyID keyID: ClientKeyID) -> RevokeReceipt {
        lock.lock()
        if let existing = revoking[keyID] {
            // Duplicate begin: fence already held for this key. Do nothing else (no second bump, no
            // second eviction) and hand back the owning lease so the caller can end/cancel it.
            lock.unlock()
            return RevokeReceipt(lease: existing, evictedCount: 0)
        }
        let lease = RevokeLease(id: nextLeaseID)
        nextLeaseID += 1
        revoking[keyID] = lease
        generation[keyID] = (generation[keyID] ?? 0) + 1
        var snapshot: [Session] = []
        for id in byClient[keyID] ?? [] {
            if let session = sessions.removeValue(forKey: id) {
                snapshot.append(session)
                keepAwake.sessionEnded(id)  // inside the lock (invariant 13)
            }
        }
        byClient[keyID] = nil
        lock.unlock()
        // Out of the lock (H-b), in THREE passes (Sol review C1). Pass 0: MARK every snapshotted
        // capability — non-blocking, so the instant this pass ends NO session under the key can
        // start a new effect, however long a sibling's in-flight effect stalls. A blocking
        // `invalidate()` here (mark+drain fused) blocked on the FIRST session whose effect was in
        // flight while every later session stayed valid with its inbound still open — the C1
        // defect that broke R8's "≤ one irreducible effect per capability" bound.
        for session in snapshot {
            session.capability.markInvalid()
        }
        // Pass 1: DRAIN each — the only bounded wait (≤ one already-in-flight irreducible effect
        // per capability). Never close-then-invalidate: the transport close alone would drain, so
        // withdrawal must land first (design §4 ordering).
        for session in snapshot {
            session.capability.drainInFlightEffect()
        }
        // Pass 2: only now the transport teardown — drop queued sends, then discard-close.
        for session in snapshot {
            session.outbound.finish()
            session.connection.closeDiscardingInbound()
        }
        return RevokeReceipt(lease: lease, evictedCount: snapshot.count)
    }

    /// Lift a key's revoke fence after a **successful** durable revoke (design §1a step 5). Lifts iff
    /// the handed lease is the current lease for its key (matching-lease-required); a stale lease is a
    /// no-op. The generation stays bumped forever — a killed session can never be resurrected.
    public func endRevoke(lease: RevokeLease) {
        liftFence(lease: lease)
    }

    /// Lift a key's revoke fence WITHOUT a durable revoke — the authenticated (LAContext-gated) escape
    /// hatch invoked only on a durable-write failure (design §1a step 5), deliberately re-admitting a
    /// still-enrolled key. Same matching-lease-required lift as `endRevoke`; a stale lease no-ops.
    public func cancelRevoke(lease: RevokeLease) {
        liftFence(lease: lease)
    }

    /// Remove the fence entry whose lease matches (leases are globally unique, so at most one key
    /// matches). Generation is untouched. A non-matching (stale) lease clears nothing.
    private func liftFence(lease: RevokeLease) {
        lock.lock(); defer { lock.unlock() }
        for (keyID, current) in revoking where current == lease {
            revoking[keyID] = nil
        }
    }

    /// Test seam: the ids of currently-registered sessions.
    func activeSessionIDs() -> Set<SessionID> {
        lock.lock(); defer { lock.unlock() }
        return Set(sessions.keys)
    }

    /// Test seam: the live SessionIDs indexed under a key (the `byClient` set).
    func sessionIDs(forClientKeyID keyID: ClientKeyID) -> Set<SessionID> {
        lock.lock(); defer { lock.unlock() }
        return byClient[keyID] ?? []
    }

    /// Send a file to the connected iPhone (Mac→iPhone transfer): an offer then ordered 64 KB
    /// chunks, interleaved with the live stream over the same connection.
    public func sendFile(name: String, data: Data, to sessionID: String) {
        lock.lock()
        let session = sessions[sessionID]
        lock.unlock()
        guard let session else { return }
        let transferID = UInt32.random(in: 1...UInt32.max)
        // Back-pressured feeding via the lane's awaitable send: at most ONE chunk sits in the
        // queue at a time, so a large transfer can't head-of-line block control messages (lock
        // status, clipboard, cursor) behind thousands of queued chunks, memory stays ~one chunk
        // beyond the file bytes, and the byte slicing happens off the caller's (main) thread.
        // The Task self-terminates when the session lane finishes: every awaited send resumes
        // immediately and subsequent sends no-op.
        Task {
            let bytes = [UInt8](data)
            await session.outbound.send(.fileOffer(FileOffer(transferID: transferID, name: name, size: UInt64(bytes.count))))
            let chunkSize = 64 * 1024
            var offset = 0
            repeat {
                let end = min(offset + chunkSize, bytes.count)
                let isLast = end >= bytes.count
                await session.outbound.send(.fileChunk(FileChunk(transferID: transferID, isLast: isLast, data: Array(bytes[offset..<end]))))
                offset = end
            } while offset < bytes.count
        }
    }

    /// Send a message to every active client session (e.g. a `DisplaysUpdate` when the host's display
    /// configuration changes). Best-effort, ordered per session via its outbound lane.
    public func broadcast(_ message: AnyMessage) {
        lock.lock()
        let active = Array(sessions.values)
        lock.unlock()
        for session in active {
            session.outbound.enqueue(message)
        }
    }

    /// Terminate every session admitted UN-authenticated under the legacy bootstrap policy, when the
    /// rollout policy tightens to `.required` (mutual-auth §4-RESOLVED; Kimi K3 + Sol han.1 review).
    /// SYNCHRONOUS invalidation: unlike `disconnectAll`, this does NOT send a graceful `bye` first —
    /// a peer the host has stopped trusting must lose keyboard/screen/clipboard/file access at once,
    /// and a `bye` would both delay the close and (client-side) suppress the reconnect we don't owe
    /// it. Authenticated sessions are untouched. Idempotent; a no-op when none are legacy.
    public func evictLegacyAdmitted() {
        lock.lock()
        let evicted = sessions.filter { $0.value.authClass == .legacyAdmitted }
        for id in evicted.keys {
            sessions[id] = nil
            keepAwake.sessionEnded(id)  // inside the lock (invariant 13)
        }
        lock.unlock()
        // Legacy sessions carry no keyID, so `byClient` needs no update. Out of the lock, in the
        // same THREE passes as `beginRevoke` (Sol review C1 — this path still interleaved each
        // session's invalidation with its own transport teardown, the widest form of the defect):
        // MARK every evicted capability (non-blocking) …
        for (_, session) in evicted {
            session.capability.markInvalid()
        }
        // … DRAIN each (≤ one in-flight irreducible effect apiece) …
        for (_, session) in evicted {
            session.capability.drainInFlightEffect()
        }
        // … then the transport teardown: finish, then discard-close (not the draining `close()`).
        for (_, session) in evicted {
            session.outbound.finish()
            session.connection.closeDiscardingInbound()
        }
    }

    /// Close every active client session. The listener stays up and keeps advertising, so we first
    /// send a graceful `bye` (and let it flush) — the client treats that as a deliberate close and
    /// will NOT auto-reconnect, whereas a bare close looks like a network drop and would re-bind.
    public func disconnectAll() {
        lock.lock()
        let active = Array(sessions.values)
        sessions.removeAll()
        byClient.removeAll()   // clear byClient too (M-a/finding 8a — it previously cleared only sessions)
        keepAwake.endAll()     // inside the lock (M-a — previously ran after unlock, racing a new sessionBegan)
        lock.unlock()
        // Invalidate-First (H-d): withdraw every capability synchronously BEFORE the async bye/close,
        // so a deferred effect can't outlive the disconnect. `revoking`/`generation` are untouched —
        // this is the trusted disconnect, not a revoke. MARK every session first (non-blocking, Sol
        // review C1) so one session's in-flight effect can't leave its siblings acting, THEN drain.
        for session in active {
            session.capability.markInvalid()
        }
        for session in active {
            session.capability.drainInFlightEffect()
        }
        // Deliberately NOT via the outbound lane: this is the teardown path itself — the close must
        // sequence after the bye's send completes, and the lane (whose owner is being torn down)
        // offers no completion hook. The direct `bye` is trusted (not capability-gated), so it still
        // flushes and the client treats the close as deliberate (won't auto-reconnect).
        for session in active {
            Task {
                try? await session.connection.send(.bye(Bye(reason: "Disconnected by host")))
                session.connection.close()
            }
        }
    }
}

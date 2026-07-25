# Design v3 — Revoke-kills-live-sessions + ClientKeyID/generation registry + revoke UI (han.4)

Final bead of the mutual-auth epic. Implements decisions.md **2026-07-21 item 3** ("Revoke =
emergency capability withdrawal: it terminates LIVE sessions") and closes the three han.4-deferred
residuals recorded in decisions.md **2026-07-22 (han.1)** and **2026-07-23 (han.3)**: the base
gate-admit→register admission TOCTOU, full SAS window-epoch binding, and attempt-scoping the host's
in-flight decision flags. Read-only exploration produced this doc; no production code was written.

**Revision history.** v1 got an adversarial different-family design review (GPT-5.6 Sol), verdict
**REDESIGN** — nine composition holes against the LIVE code. v2 folded all nine. v2 then got a
different-family **re-review** (Sol again), verdict upgraded to **BUILD-WITH-CHANGES**: the core
**ticket / generation / fence** architecture is CONFIRMED sound (findings 1 & 9 CLOSED, finding 7
mostly closed), but five HIGH + two MEDIUM residuals remained — **all clustered around capability
LIFETIME discipline and check→effect atomicity**. v3 folds them (change-log below). Each was
re-verified against the live code it cites before folding.

**The v3 crux — one unifying invariant plus three lifetime disciplines.** v2 established *where* a
session's authority is captured (the ticket, at authorization) and *when the epoch bumps* (revoke).
v3 nails down *when the authority DIES and who is allowed to act in the gaps*:

- **Invalidate-Capability-First (the named invariant, H-d).** On **every** terminal path — normal
  serve-defer, cancellation-driven shutdown, `disconnectAll`, `evictLegacyAdmitted`, a failed
  post-register recheck, a register-reject self-close, and revoke — the capability is withdrawn
  **before any async teardown** (and before the registry removal on the single-session paths; the
  batch paths unlink under the lock first, see §7 invariant 1). v2 only invalidated on the revoke
  path, so a deferred effect (a queued MainActor pasteboard write) could outlive a *normal*
  disconnect on a still-valid capability.
- **Revoke never blocks the registry lock on an effect (H-b).** `beginRevoke` under `HostControl.lock`
  only bumps the generation, sets the fence, **snapshots** the target capabilities, and unlinks them
  from the registry. Invalidation of those snapshots — which may briefly *wait* on one in-flight
  effect — happens **out of the lock**. Inbound effects are size-capped per message type and checked
  at each **irreducible** side effect, never across a compound multi-CGEvent message.
- **`RevokeLease` fails CLOSED (H-c).** Revoke carries an opaque lease that coalesces duplicate
  begins, requires the matching lease to end, and **retains the fence on a durable-write failure** —
  K stays unauthorizable until a successful durable revoke, with Retry and an authenticated Cancel.
- **Post-await recheck (H-e).** The durable `isAuthorized` await SUSPENDS; a revoke can invalidate
  during it. v3 rechecks the capability the instant the await returns, and capability-gates lane
  authorization **and** every post-admission direct send (`ServerHello`, initial lock-status, pong).

Binding upstream: `docs/superpowers/specs/2026-07-01-revocable-pairing-mutual-auth.md` (§2 revocable
enrollment), the han.3 ceremony spec (`2026-07-23-enrollment-ceremony-design.md`), and the ADRs.

**Threat model for this bead.** A device was enrolled and is *live* (streaming, injecting input,
reading clipboard, receiving files). The owner revokes it. Today `PairingStore.revoke`
(`PairingStore.swift:148`) only makes the *next* handshake fail closed — the live session keeps full
capability, and active QUIC traffic prevents the ~30 s idle timeout from bounding it. han.4 makes
revoke sever the live session synchronously, correctly, and race-safely against reconnects and
re-enrollments of the same key — **for the process that owns hosting** (the app; cross-process is
§6c).

### Change-log — v2 re-review (finding → precise change)

- **H-a** (finding 6 residual — cross-process lost update on `touch`) → **folded.** A cache-bypass
  read does not close the race: `touch`'s read-modify-write of the *whole* map has no cross-process
  CAS, so a warm `touch(K)` that read K-present can still write its snapshot back **after** another
  process revoked K, durably restoring K. v3 stops `touch` from ever writing the authorization set:
  `lastSeen` moves to **separate storage** (its own keychain item), mutated only by `touch`; the
  authorization map is mutated only by `enroll`/`revoke`. `touch` can no longer re-add a key by
  construction (§6c, invariant 9). Non-persisting `touch` is the documented fallback. Barrier test
  in §8.
- **H-b** (R2 residual — unbounded `perform` effects + lock-held invalidate → revoke starvation) →
  **folded.** (1) Inbound per-message-type **size caps** at the serve boundary bound the number of
  irreducible effects per message (a `.typeText` cap well under `Frame.maxBodyLength`=16 MiB, an
  inbound-clipboard cap = `Frame.maxClipboardBytes`, a `.fileChunk` cap ≈ the 64 KiB sender chunk).
  (2) The capability is checked at each **irreducible** OS effect (one CGEvent post, one pasteboard
  write, one file-chunk write), never wrapped around a whole compound message. (3) `beginRevoke`
  **snapshots** target capabilities under `HostControl.lock` and withdraws them **OUT of the lock**,
  as a non-blocking **mark-all** pass followed by a **drain-all** pass (§1a, §4). Net: a drain waits
  at most one irreducible effect, never while `HostControl.lock` is held, and never on a *sibling's*
  effect (§10 R2/R8 now bounded).
- **H-c** (finding 2 residual — no revoke owner, fails OPEN on durable failure) → **folded.**
  `revoking` becomes `[ClientKeyID: RevokeLease]`; `beginRevoke` coalesces/rejects a duplicate begin
  for K, `endRevoke` requires the matching lease, and a durable-write failure **retains** the fence
  (fail closed) with Retry + authenticated Cancel (§1a steps 3–6, §2 `RevokeLease`, invariant 6).
- **H-d** (NEW — capability lifetime ends too late/never on non-revoke teardown) → **folded** as the
  named **Invalidate-Capability-First** invariant, enumerated over every terminal path (§4,
  invariant 1). This is the unifying correction of the pass.
- **H-e** (findings 4/5 residual — post-register suspension resumes into unguarded startup/sends) →
  **folded.** A **post-await capability recheck** gates the resume; lane authorization and every
  post-admission direct send (`ServerHello`, initial lock-status, pong) are capability-gated;
  `closeBoundLanes` is terminalized so a racing late bind cannot survive closure (§1b, §4, §5).
- **M-a** (finding 8 residual — `disconnectAll` breaks keepAwake ordering) → **folded.**
  `keepAwake.endAll()` moves **inside** `HostControl.lock` (HostControl→KeepAwake→IOKit order) and
  `byClient` is cleared there too (§2, invariant 11).
- **M-b** (composition points unspecified) → **folded.** `beginRevoke` does its out-of-lock teardown
  **internally** and returns an opaque **public** `RevokeReceipt`; `Session`/`OutboundLane` stay
  private. `HostRunner.run` mints **one process-local `HostControl`** when the caller supplies none,
  so the CLI works (§2).
- **Minor** (finding 7 tail — `enqueue`'s Bool can re-arm a finished buffer) → **folded.** `enqueue`
  returns a **terminal verdict** (`.accepted(pauseReceive:)` vs `.droppedFinished`); the receive loop
  never re-arms on `.droppedFinished` (§2, §4).

**CONFIRMED — unchanged in v3:** finding 1 (ticket at authorization, §3), finding 9 (`WindowLease` +
per-task decision tokens, §6a/§6b), R1 (nested `HostControl→KeepAwake→IOKit` lock safe today — the
one-way KeepAwake contract, §10), R6 (Order-A forced-reconnect is the correct conservative
direction, §3/§10). The v1→v2 corrections (ticket-at-authorization, one linearized fenced revoke,
effect-boundary + outbound capability checks, admission ahead of producers) stand.

---

## 1. Flow

### 1a. Revoke path, end-to-end (one linearized, lease-owned operation)

Revoke is authored in `HostAppModel.revoke(_ id:)` and runs as a single ordered sequence. The two
authorities — the shared durable `PairingStore` actor and the in-process `HostControl` — are
**ordered within the operation and fenced by a lease**, never two independent writes.

1. **UI entry.** The menu-bar "Paired devices" surface lists `pairings.list()` — for each
   `EnrolledClient` (`PairingStore.swift:26`): `deviceName`, `KeyFingerprint.short(forPublicKey:)`,
   and `lastSeen` (now joined from the separate lastSeen item, §6c). User taps **Revoke** on one row.
2. **Destructive-action gate (MANDATORY — product decision 1).** A confirmation dialog
   ("Revoke 'iPhone'? It will lose access immediately.") **and** an `LAContext`
   `.deviceOwnerAuthentication` evaluation, mirroring the enrollment-Allow/Deny gate at
   `HostAppModel.approveEnrollment` (`HostAppModel.swift:202`, `denyEnrollment` `:232`). Only a
   positive result proceeds. This is not optional: CGEvents dispatch globally, so an ungated Revoke
   button is remotely clickable with zero local presence — the exact hole the enrollment LAContext
   gate closes.
3. **Live fence + kill (internal to `beginRevoke`; lock-snapshot then out-of-lock invalidate).**
   `let receipt = control.beginRevoke(clientKeyID: K)`. `beginRevoke` returns an opaque public
   `RevokeReceipt` and performs the whole live teardown itself (M-b — `Session`/`OutboundLane` never
   escape). Internally:
   - **Under `HostControl.lock`, in order (H-b — nothing that can *wait* runs here):**
     a. **Coalesce:** if `revoking[K]` already holds a lease → this is a duplicate begin; do nothing
        else and return the existing receipt (idempotent, H-c). Otherwise mint a fresh `RevokeLease`
        and set `revoking[K] = lease` (the **fence**: `admissionTicket(for: K)` and `register` for K
        are rejected while K ∈ `revoking`).
     b. `generation[K] += 1` (§3).
     c. **Snapshot** every live session in `byClient[K]` (their `capability` + `outbound` +
        `connection`); remove each from `sessions` and from `byClient[K]`; `keepAwake.sessionEnded`
        each — all under the lock. **No capability invalidation and no transport work under the lock.**
   - **Out of the lock (H-b, H-d ordering), in THREE passes** (Sol review C1): pass 0
     `capability.markInvalid()` on **every** snapshot — the NON-blocking half, so the instant this
     pass ends no session under the key can START a new effect; pass 1
     `capability.drainInFlightEffect()` on each — the only bounded wait (≤ one *already*-in-flight
     irreducible effect apiece, §4); pass 2, per snapshot, `session.outbound.finish()` (drop queued
     clipboard/cursor/file/broadcast sends) then `session.connection.closeDiscardingInbound()` (§4).
     Separate passes, not one interleaved loop: a fused blocking `invalidate()` per session (v3's
     first shape) **blocked on the first session whose effect was in flight** — a stalled
     `FileHandle.write` — while every later session under the key stayed valid with its inbound
     still open, so a revoked device kept full keyboard/pointer/clipboard/file control through its
     second session for the whole stall. That is strictly wider than R8's per-capability bound; the
     mark/drain split is what restores it. **No graceful `bye`** (unlike `disconnectAll`,
     `HostControl.swift:120`).
   - Return `RevokeReceipt(lease:, evictedCount:)`.

   **Why the registry unlink precedes withdrawal here, and why that is still Invalidate-First**
   (Sol review I7 — this used to read as a contradiction against §7 invariant 1, which said
   invalidation runs *before* registry removal; the implementation follows the ordering below and
   invariant 1 has been restated to match). Two constraints pull in opposite directions:
   - **H-b forbids waiting under `HostControl.lock`.** Everything under the lock must be
     non-blocking, so the *drain* (which can wait out an in-flight effect) cannot run there — hence
     snapshot + unlink under the lock, withdrawal after it.
   - **Invalidate-First is about the TEARDOWN order, not about the registry.** What it forbids is
     close-then-invalidate: the transport close alone drains, so a session whose transport is torn
     down while its capability is still live can still act. Withdrawal must therefore precede
     `outbound.finish()` / `closeDiscardingInbound()` / the `bye` Task — and it does, in pass 0/1.

   The unlinked-but-not-yet-withdrawn interval that this ordering creates is made safe by the
   **fence** (no new session for K can register into the gap) plus the **non-blocking mark**: pass 0
   ends the interval for *every* snapshotted session at once, without waiting on any of them, so no
   NEW effect can start in it. What remains is the ≤ one already-in-flight irreducible effect per
   capability (R8) — bounded, and the accepted price of not freezing the registry lock.
4. **Durable removal (second), intent-first.** `try await pairings.revoke(id: K)` on the **shared**
   `PairingStore` instance (§2). `migrationComplete` is never cleared (`PairingStore.swift:147`), so
   revoking the last device keeps the host `.required` (decision 2). Internally `revoke` records a
   **durable revocation intent** for K in its own keychain item **before** attempting the removal, and
   clears it only once the removal has landed (§6d) — that intent, not the in-memory fence, is what
   makes step 5's fail-closed claim survive a process restart, **when the intent write lands.**
   `revoke` reports which of **three** it got: `RevokeIncomplete.fencedDurably`, `.notDurable`
   (proven absent), or `.durabilityUnknown` (the intent item could not be read, so nothing is known —
   Sol pass 3 N1).
5. **Finalize — CONDITIONAL on durable success (H-c, fail CLOSED).**
   - **Durable revoke succeeded** → `control.endRevoke(lease: receipt.lease)`. `endRevoke` lifts the
     fence **iff** the lease it is handed is the current lease for K (matching-lease-required — a
     stale lease never lifts a newer op's fence). The generation stays bumped forever. The durable
     intent clear is *attempted* by `revoke` itself. **Honest bound (Sol re-review):** that final clear
     is best-effort, so a successful revoke guarantees K is *gone from the authorization item* — it
     does **not** guarantee "no intent left". A failed clear leaves an inert ORPHAN intent for a key
     that is no longer enrolled: it authorizes nobody, `pendingRevocations()` filters it out, and the
     next `enroll`/`revoke` of that id discharges it — but nothing sweeps it, and `enroll` now THROWS
     rather than reporting success if it cannot discharge it (§6d item 8, R11).
   - **Durable revoke threw** (keychain error) → **do NOT call `endRevoke`.** How many fences K is
     behind depends on what the intent item did, and the three cases are **materially different** —
     the UI must not render them as one state. The split is by what was **proven**, not by what
     succeeded: a failed intent *write* proves absence, a failed intent *read* proves nothing:
     - **`.fencedDurably`** — the intent item was READ and K is in it (already recorded by an earlier
       attempt, or this call's write landed). K is unauthorizable via **two independent
       fences**: the retained in-process fence (K ∈ `revoking`, dies with the process) *and* the
       **durable revocation intent** from step 4 (§6d, Sol review I5), for which `isAuthorized` /
       `authorizedClient` fail closed even from a FRESH `PairingStore` in a brand-new process, and
       even though K's authorization record is still present. Without it, "revoke → durable write
       throws → app quit/crash before Retry or Cancel" silently re-admitted K at generation 0 on the
       next launch with the UI showing nothing.
     - **`.notDurable`** — the intent item was READ, K was **not** in it, and the intent write ALSO
       failed. This is the natural CORRELATED case: both items live in the same keychain, so whatever
       broke the authorization write usually broke the intent write. **Nothing durable was recorded**,
       and that is *proven*, not assumed. The ONLY thing denying K is the in-process fence, and a
       quit/crash/restart **re-admits K**. This is not fixable by writing somewhere else (if nothing
       durable can be written, nothing durable can deny from a cold store — an implementation cannot
       conjure a restart-surviving denial out of a failed write), so the requirement is to **fail
       LOUD**: `PairingStore.revoke` throws `.notDurable`, `HostAppModel.revokeDurabilityWarnings`
       records the id as `.notDurable`, and the row reads *"revoke NOT saved — regains access if
       Portview restarts / blocked only while Portview runs"* instead of the plain "revoke incomplete".
       Retry re-attempts the intent write on every call, so a transient keychain failure **self-heals**
       into `.fencedDurably` and the warning clears (with a message saying so).
     - **`.durabilityUnknown`** — the intent item could not be **read**, so `recordRevocationIntent`
       wrote nothing and nothing is known (Sol pass 3 N1). Collapsing this into `.notDurable` was
       **factually wrong**, not merely conservative. Counterexample: an earlier attempt durably
       recorded K's intent and failed only the removal (`.fencedDurably`); on Retry the intent READ
       throws, so the durable `{K}` blob is untouched and a fresh process still denies K — while the
       old code announced the exact opposite ("REGAINS ACCESS if Portview restarts"). It also
       contradicted the row's own last-known pending set, which still listed K. So this is its own
       case, and its copy must be **conditional**: `HostAppModel.revokeDurabilityWarnings` records
       `.unverified`, and the row reads *"couldn't verify the revoke was saved — it MAY regain access
       if Portview restarts"* — or, when the last successful read of the intent item **did** list K,
       *"couldn't re-check the saved revoke — the pairing store is unreadable"*, which never raises
       re-admission at all. Note the store still fails closed under an unreadable intent item (it
       denies EVERYONE, §6d item 7), so the honest statement really is "unknown", not "denied" or
       "re-admitted". Retry re-attempts the read, so this too self-heals in either direction.
     The op is surfaced as **incomplete** with two authenticated actions, both of which must work with
     OR without an in-process lease (after a restart there is none to reuse):
     - **Retry** — re-run step 4. Same process: on success, `endRevoke(lease:)` under the *same*
       retained lease (matching-lease semantics unchanged). After a restart: re-attempt the durable
       removal alone — there is no fence to lift in a fresh process, and a successful removal clears
       the intent.
     - **Cancel** — the `LAContext`-gated escape hatch that re-admits the still-enrolled K (the owner
       accepts the risk for a permanently-wedged keychain). It removes the **durable intent** first
       (`pairings.cancelRevocationIntent(id:)`) and then, only if this process still holds one,
       `control.cancelRevoke(lease:)` (which still requires the matching lease). If the durable clear
       throws, BOTH fences stay and the row stays incomplete — a Cancel that cannot be made durable
       must not report a re-admission the next launch would revert.
   The live kill in step 3 already happened and the generation bump is permanent regardless, so a
   failed durable step can never resurrect a killed session — it only leaves K live-*re-admittable*,
   which the retained fence blocks in-process and the durable intent blocks across restarts
   (new-risk R5, fail-closed *durably* **iff** the intent is recorded; `.notDurable` is
   process-lifetime only and `.durabilityUnknown` is of unknown lifetime — both reported as such).
6. **UI refresh.** Reload `pairings.list()` **and** `pairings.pendingRevocations()` → the revoked row
   disappears (on durable success); a row whose intent is still recorded stays visible in the
   incomplete state, on this launch and every later one until Retry or Cancel resolves it. A
   `.notDurable` row is visible only for THIS process's lifetime (there is nothing durable to rebuild
   it from) — which is exactly why its copy has to say so while the user can still act on it. A
   `.durabilityUnknown` row may or may not rebuild after a restart (that is precisely what could not be
   verified), so its copy hedges instead of claiming either.
   `pendingRevocations()` returns `.unreadable` rather than an empty set when the intent item cannot be
   read, and the surface renders "Pairing store unreadable — no device can connect…": on that read the
   store denies EVERY device, so a clean empty list would be a lie in the reassuring direction. **If
   it was the last device (product decision 2):** surface the locked-out copy — e.g. "That was your
   last paired device. Portview now accepts no one until you re-pair in person." The host stays
   `.required`; bootstrap never reopens; there is no remote self-recovery. Intended fail-closed
   behavior. On a durable failure the row stays visible in an "incomplete — Retry / Cancel" state.

**Why fence-then-durable, not durable-then-fence (finding 2, unchanged).** v1 did `await
pairings.revoke` *then* `control.revoke`. Between those two awaits a queued enrollment for K could
run and stamp the *old* generation. v3's bump + fence are synchronous and first; the durable removal
is ordered inside the operation; the lease-owned fence (not durable-write ordering) closes the window
where a re-enroll's session could interleave. Reachability caveat in §4.

### 1b. Admission-atomicity — corrected `serveSession` ordering (findings 1, 5; H-e)

The material change: **the admission ticket, register, the durable recheck, AND a post-await
capability recheck move AHEAD of every producer and of `ServerHello`.** In the LIVE code the outbound
lane (`HostRunner.swift:603`), clipboard polling (`:617`), cursor pump (`:643`), `didBuildScaffolding`
(`:597`), and the `ServerHello` send (`:703`) all precede `control.register` (`:709`) — so a local
clipboard change can be sent to a peer that is never confirmed still-authorized, and a revoke landing
in the gate→register gap streams (and *sends*) unrevoked.

Corrected `serveSession` sequence (only the reordered spine; unchanged peripheral logic elided):

```
1.  inbound = MessageReader(connection.inbound)                        // :530 (unchanged)
2.  firstMessage = inbound.next(deadline: 5s); role-lock SAS vs Hello  // :531–543 (unchanged)
3.  entryMode; if .required { control.evictLegacyAdmitted() }          // :555–560 (unchanged)
4.  outcome = serveAuthGate(...)                                       // :561 — NOW returns a ticket:
        · authenticated(deviceID: K, ticket: T)   where T = control.admissionTicket(for: K)
          captured INSIDE the gate, immediately AFTER signature verify and BEFORE the durable
          authorizedClient lookup (§3, §5). Gate rejects if the fence returns nil (K revoking).
        · unknownKey(publicKey)  → run enrollment ceremony; on enroll success capture
          T = control.admissionTicket(for: K) POST-enroll.
        · legacyAdmitted → ticket with keyID = nil.
        · rejected → close, return.
5.  guard firstDisplay = registry.current().first else close+return    // :596 (unchanged position)
6.  --- ADMISSION, before ANY producer or ServerHello ---
        capability = SessionCapability()                               // NEW
        outbound = OutboundLane(connection, capability)                // inert: no producer attached
        sessionID = UUID().uuidString
        result = control.register(sessionID, connection, outbound,
                                  authClass, ticket: T, capability)     // sync, locked: fence + gen check
        guard result == .admitted else { capability.invalidate();      // Invalidate-First (H-d)
                                         outbound.finish();
                                         connection.closeDiscardingInbound(); return }
        // durable backstop (keyed sessions only; legacy skips) — this await SUSPENDS:
        let stillDurable = (T.keyID == nil) || (await pairings.isAuthorized(id: T.keyID))
        // POST-AWAIT RECHECK (H-e): a revoke may have invalidated during the suspension.
        guard stillDurable && capability.isValid else {
            capability.invalidate(); control.deregister(sessionID)      // Invalidate-First
            outbound.finish(); connection.closeDiscardingInbound(); return }
7.  didBuildScaffolding?()                                             // NOW fires post-recheck
8.  --- PRODUCERS + capability-gated handshake sends (only now) ---
        server.handle(hello); guard capability.isValid else terminalize
        if let token, lanes = router.authorizeLanesOnce(...) { bind task }  // gated on isValid
        guard capability.isValid else terminalize; connection.send(.serverHello)   // gated (H-e)
        emit(.deviceConnected(id: sessionID, name: sanitizedDeviceName))            // :710
        if locked && capability.isValid { connection.send(.hostLockStatus(true)) }  // gated (H-e)
        clipboard.start { text in guard capability.isValid; outbound.enqueue(...) } // :617 moved here
        cursorPump = CursorReportPump(lane: outbound); injector = makeInjector(..., capability)
9.  message loop over SUBSEQUENT inbound (first Hello already consumed in step 8):
        each SIZE-CAPPED privileged inbound effect goes through capability.perform at its
        IRREDUCIBLE boundary (§4); .ping's pong reply is capability-gated (H-e).
10. defer (Invalidate-First, H-d): capability.invalidate(); clipboard.stop; fileReceiver.cancelAll;
          videoTask/audioTask/laneBindTask cancel; router.closeBoundLanes(); currentCapture.stop;
          outbound.finish; connection.close; if sessionID { control.deregister(sessionID);
          emit(.deviceDisconnected) }
```

`capability.invalidate()` is the **first** statement of the teardown defer (step 10) — before
`clipboard.stop`, before `control.deregister`, before any cancel/close — so a deferred MainActor
pasteboard write (or any queued effect holding the capability) fails closed on a *normal* disconnect,
not only on revoke (H-d). The direct handshake sends in step 8 (`ServerHello`, initial lock-status)
and the pong in step 9 are each preceded by an `isValid` check (H-e); their residual is the same
bounded already-in-transport class as the outbound stream (§4). The `.clientHello` handshake is
pulled out of the message loop into step 8 and run once; `authorizeLanesOnce` still refuses after the
first call (`HostLaneRouter.swift:76`).

---

## 2. Units (responsibility · pattern to mirror @ file:line · dependencies)

Signatures below are **spec-derived** where they name a contract this bead fixes, and **named-not-
prescribed** where they are codebase idioms the implementer must read and mirror.

### Changed

- **`HostControl.Session`** (`HostControl.swift:16`, stays **private**). *Add*: `keyID: ClientKeyID?`
  (nil for legacy), `admittedGeneration: UInt64`, and `capability: SessionCapability` (§4). Mirror the
  existing plain-value struct. Never escapes `HostControl` (M-b — `beginRevoke` returns a public
  receipt, not `[Session]`).
- **`HostControl` state** (`HostControl.swift:25–29`). *Add* four lock-guarded fields:
  `byClient: [ClientKeyID: Set<SessionID>]`, `generation: [ClientKeyID: UInt64]`,
  `revoking: [ClientKeyID: RevokeLease]` (**a map, not a set — H-c**), and the lease counter/minter.
  All under the existing single `NSLock`. **Invariant:** `byClient` holds a **set** of SessionIDs,
  never a single slot — two concurrent/reconnecting sessions under one key must both be indexed
  (finding 1's set requirement); registration never overwrites a sibling.
- **`HostControl.admissionTicket(for:) -> AdmissionTicket?`** (NEW). Lock-guarded read: returns `nil`
  iff K ∈ `revoking` (fence); else `AdmissionTicket(keyID: K, generation: generation[K] ?? 0)`. Pure
  snapshot — reserves no held resource. Called from `serveAuthGate` (§5).
- **`HostControl.register`** (`HostControl.swift:40`). Signature gains `ticket: AdmissionTicket` and
  `capability: SessionCapability`; returns `AdmissionResult` (`.admitted` | `.rejected`). Under the
  lock, for a keyed ticket: `guard revoking[K] == nil && ticket.generation == (generation[K] ?? 0)
  else return .rejected`; else insert into `sessions`, insert the SessionID into `byClient[K]`, and
  call `keepAwake.sessionBegan(id)` **inside the lock** (finding 8b). Legacy tickets (`keyID == nil`)
  skip the fence/generation check. The generation half of the admission fix.
- **`HostControl.deregister`** (`HostControl.swift:48`). Under the lock: remove from `sessions`,
  remove the SessionID from `byClient[keyID]` (drop the key when its set empties), and
  `keepAwake.sessionEnded` **inside the lock**. Removes precisely by SessionID — never wipes a
  reconnecting sibling. **Does NOT invalidate the capability** — the *caller's* teardown path already
  invalidated first (Invalidate-First, H-d); deregister is registry bookkeeping only.
- **`HostControl.beginRevoke(clientKeyID:) -> RevokeReceipt`** (NEW, **public**). §1a step 3: coalesce
  a duplicate begin; else mint lease + fence + bump + snapshot + unlink + keepAwake-end (all under the
  lock, **no invalidate/close under the lock**), then **out of the lock** `markInvalid()` on every
  snapshot → `drainInFlightEffect()` on every snapshot → finish + `closeDiscardingInbound` each.
  Returns the opaque `RevokeReceipt`. Teardown is internal
  (M-b). `HostAppModel.revoke` orchestrates begin → `await pairings.revoke` → end/retain (§1a).
- **`HostControl.endRevoke(lease:) / cancelRevoke(lease:)`** (NEW). `endRevoke` removes K from
  `revoking` **iff** `revoking[K] == lease` (matching-lease-required); the generation stays bumped.
  `cancelRevoke` is the same fence-lift but is the authenticated escape hatch invoked only from the
  `LAContext`-gated Cancel action on a durable failure (§1a step 5). Both no-op on a stale lease.
- **`HostControl.evictLegacyAdmitted`** (`HostControl.swift:106`). Upgrade to the §4 primitive AND
  Invalidate-First: under the lock, snapshot the legacy sessions + `keepAwake.sessionEnded` + remove
  from `sessions`; **out of the lock**, the same three passes as `beginRevoke` — mark all, drain all,
  then `outbound.finish()` + `closeDiscardingInbound()` each — replacing the draining
  `connection.close()` at `:113` (Sol review C1: this path was still interleaving). Legacy
  sessions carry no `keyID`, so `byClient` needs no update. Closes the han.3 residual and the H-d
  "legacy eviction leaves the capability valid" hole.
- **`HostControl.disconnectAll`** (`HostControl.swift:120`). Under the lock: snapshot sessions,
  `sessions.removeAll()`, **clear `byClient`** (M-a/finding 8a — it currently clears only `sessions`,
  `:123`), and `keepAwake.endAll()` **inside the lock** (M-a — it currently runs after `unlock`,
  `:124–125`, racing a new `sessionBegan`). Out of the lock: `markInvalid()` on **all** snapshots then
  `drainInFlightEffect()` on all (H-d — stops a deferred effect outliving the disconnect, and one
  session's stalled effect cannot leave a sibling acting), THEN the graceful-`bye`
  Task (the direct `bye` send is not capability-gated, so it still flushes — this is the *trusted*
  disconnect). `revoking`/`generation` untouched.
- **`HostRunner.run`** (`HostRunner.swift:97`). `control: HostControl? = nil` stays for callers that
  supply one (the app, `HostAppModel.swift:49/120`), but when it is `nil` **mint one process-local
  `HostControl` here** and pass it **non-optionally** into `serveSession` (M-b) — so the CLI
  (`PortviewHostApp.swift:17`, passes no control) mints tickets, registers capabilities, and evicts.
  The CLI has no revoke UI; that is fine (revoke is an app-menu action).
- **`HostRunner.serveSession`** (`HostRunner.swift:510`). Reordered per §1b: admission + durable
  recheck + **post-await capability recheck** ahead of producers; ticket threaded from the gate;
  every privileged inbound effect **size-capped** then wrapped in `capability.perform` at its
  irreducible boundary (§4); `ServerHello`/initial lock-status/pong capability-gated (H-e); the
  teardown defer's **first** statement is `capability.invalidate()` (H-d).
- **`HostRunner.serveAuthGate`** (`HostRunner.swift:813`). *Add* a reservation seam
  `admissionTicket: @Sendable (ClientKeyID) -> AdmissionTicket?` (bound to `control.admissionTicket`).
  Immediately after `ClientAuthCrypto.verify` (`:847`) and **before** `pairings.authorizedClient`
  (`:851`), compute `K = PairingStore.deviceID(forPublicKey:)` and capture the ticket (§3, Order-A).
  Fence-nil → reject (`.revoking`). On the authenticated path return `.authenticated(deviceID: K,
  ticket:)`. The `pairings.touch` at `:857` stays but now writes only the separate lastSeen item
  (§6c). Keeps the closure-seam testability the gate already has.
- **`HostRunner.pumpVideo` + audio child** (`HostRunner.swift:1006`, audio task `:1027`). Take the
  session `capability`. Check `capability.isValid` **immediately before each post-encode send** (video
  `:1098`, audio `:1029`, stats `:1118`) — the live code only checks `Task.isCancelled` *before* the
  encode (`:1047`), never after, so a frame encoded the instant before revoke still sends (finding 4).
  Drop the send when invalid.
- **`HostLaneRouter`** (`HostLaneRouter.swift:39`). Take the session `capability`; `send` (`:156`)
  drops when `capability.isValid` is false. *Add* `closeBoundLanes()` (called from the serve defer)
  that sets a **terminal `closed`** flag AND closes the retained secondary senders (`lanes`, `:48`);
  `bind` (`:92`) additionally guards on `!closed` so a **late bind racing closure is refused** (H-e —
  today `bind` only checks `resolved`/`fallenBack`, `:95–96`). Late-bind protection otherwise unchanged.
- **`OutboundLane`** (`OutboundLane.swift:14`, stays **private**). Its production sink (`:108–110`)
  gates on `capability.isValid` before `connection.send`, so a message already handed to the sink is
  dropped if the capability flipped between `take()` and the send (finding 4's CursorReportPump
  residual). `finish` (`:84`) unchanged; revoke/teardown call it synchronously **after** invalidation.
- **`ClipboardSync.applyRemote`** (`ClipboardSync.swift:35`). Take the session `capability`; the
  deferred `Task { @MainActor }` wraps the **single** pasteboard mutation in `capability.perform { …
  }` (§4, finding 3 + H-d — the write currently runs on a MainActor task that can land AFTER revoke
  OR after a normal disconnect). Inbound clipboard text is size-capped at the serve boundary (H-b,
  = `Frame.maxClipboardBytes`) before it reaches here.
- **`InputInjector`** (`InputInjector.swift:9`). Take the session `capability`. Route the per-event
  post through `capability.perform { self.postEvent(event) }` at the **`postEvent` seam** — the
  irreducible boundary — so a large `.typeText` (`:117–127`, 2 CGEvents/char) is checked *per event*,
  not wrapped whole (H-b). Combined with the serve-boundary `.typeText` size cap, `invalidate()` waits
  at most one event and a capped message bounds wasted pre-invalidate work. The process-wide `paused`
  flag (`:16–29`) is unchanged (orthogonal lock-monitor gate).
- **`FileReceiver.chunk`** (`FileReceiver.swift:52`). The single `handle.write(contentsOf:)` (`:60`)
  is the irreducible effect. **`FileReceiver` SELF-GUARDS** it: `chunk` takes the session capability
  and wraps only its own `handle.write` in `capability.perform` (Task 5, landed). The serve loop
  therefore calls `fileReceiver.chunk(chunk)` **UNWRAPPED** — do NOT add an outer
  `capability.perform { fileReceiver.chunk(chunk) }`: `SessionCapability.perform` is non-reentrant
  (`NSLock`), so an outer wrap around a self-guarding chunk would self-deadlock on a *valid*
  capability (Task-5 review). One gate at the irreducible write, not two. Size cap: `chunk.data.count`
  is capped at the SERVE boundary (Task 8, H-b). Per-file/per-session caps (`:56`) unchanged.
- **`FileReceiver.offer`** (final-review M-2). `offer`'s single `FileManager.createFile` is an
  irreducible effect of its own — an ungated `offer` leaves a 0-byte, client-named file in
  ~/Downloads when a `.fileOffer` lands through the bounded R9 parked-waiter window. `offer`
  SELF-GUARDS that one `createFile` in `capability.perform` and returns without registering the
  transfer when the gate is closed (so a following `chunk` is a no-op too). Same rule as `chunk`:
  the serve loop calls `fileReceiver.offer(offer)` **UNWRAPPED**.
- **`InboundBuffer`** (`InboundBuffer.swift`). *Add* `finishDiscardingBuffered()`: under the lock,
  clear `controlLane`/`controlHead`/`controlBytesBuffered`/`audioLane`/`videoLane`, set `finished =
  true`, take + resume any `waiter` with `nil`. **Change `enqueue`** (`:79`) to return a **terminal
  verdict** instead of a bare `Bool`: `enum EnqueueOutcome { case accepted(pauseReceive: Bool); case
  droppedFinished }` — under the lock, `guard !finished else { return .droppedFinished }` (it
  currently appends unconditionally — finding 7); the shared lock linearizes a racing receive-callback
  enqueue against the discard (runs fully before → cleared, or fully after → `.droppedFinished`).
  Contrast: `finish()` (`:153`) deliberately *drains*.
- **`PortholeConnection`** (`PortholeConnection.swift`). *Add* `closeDiscardingInbound()`: mirror
  `close()` (`:129`) but call `inboundBuffer.finishDiscardingBuffered()` **before**
  `connection.cancel()` (finding 7). Propagate the new verdict: `ingest` (`:239`) maps
  `.droppedFinished` so `receiveNext` (`:210–228`) / `adoptClassifiedPrefix` **never re-arm** a
  finished buffer (minor — today `:227/:242` re-arm from the pause `Bool`).
- **`PairingStore`** (`PairingStore.swift`). Split `lastSeen` into a **separate keychain item**
  (§6c, H-a). The authorization item (`Persisted.clients` + `migrationComplete`) is mutated only by
  `enroll`/`revoke`. `touch(id:)` (`:156`) reads-modifies-writes only the lastSeen item; it can no
  longer re-add a key to the authorization set. `enroll` seeds `lastSeen[K]`; `revoke` best-effort
  deletes `lastSeen[K]`. `list()` (`:114`) joins the lastSeen item (default → `enrolledAt` when
  absent) and may prune orphan lastSeen keys absent from the auth set. Best-effort: a thrown lastSeen
  read/write no-ops (preserves the mid-session keychain-lock resilience the actor exists for).
  **Two further changes from the Sol re-review:**
  - **C2 — the mutation path never reads the warm cache.** `mutableState()` re-reads the durable item
    immediately before every read-modify-write and propagates a read failure; only the AUTHORIZATION
    read path (`readState()`) keeps its warm cache. The asymmetry is the point: a stale-but-known-good
    ALLOW is bounded by the fence + the durable intent, whereas a stale WRITE is permanent (§6d).
  - **I5 — a third keychain item holds pending revocation INTENTS.** `revoke` records K's intent
    before attempting the removal and clears it after; while recorded, `isAuthorized`/`authorizedClient`
    fail closed for K. New public accessors `pendingRevocations() -> Set<String>` (UI: which enrolled
    rows are mid-revoke) and `cancelRevocationIntent(id:)` (the durable half of Cancel). `list()` stays
    the INVENTORY view — it deliberately still shows an intent-fenced device so the UI can finish the
    wedged revoke. `enroll` clears a pending intent (an attended re-pair supersedes it).
- **`SASPairingControl`** (`SASPairingControl.swift`). *Unchanged from v2 (CONFIRMED).*
  `registerAttempt` (`:89`) returns an opaque `WindowLease?`; `claimCodeDisplay` (`:101`) validates
  the window is still open under that lease; the lease threads through reveal/code/confirm; the
  limiter (`:14`) mints a fresh lease id in `open` (`:30`).
- **`HostAppModel`** (`HostAppModel.swift`). Promote the inline `PairingStore()` (`:122`) to a
  **stored property** built once (mirror stored `control`/`authority` at `:49`/`:61`); pass that same
  instance into `events(...)` **and** the revoke action. *Add*: an `enrolledDevices` observable (from
  `pairings.list()`, refreshed on surface-open + after enroll/revoke) and `revoke(_ id:)` running §1a
  steps 2–6 including the durable-failure Retry/Cancel branch. Decision flags (`:86`/`:92`) become
  per-task tokens (§6b, CONFIRMED). The `control` at `:49` already exists — no minting needed here
  (the mint-on-nil is the CLI path). **Restart-durable incomplete state (§6d, I5):** the in-memory
  `revokeFailures: [id: RevokeLease]` is joined by `pendingRevocations: Set<String>` refreshed from
  `pairings.pendingRevocations()` on every `refreshEnrolledDevices()`; `revokeIncomplete(id)` (either
  source) is what the row renders Retry / Cancel from, so a revoke wedged in a *previous* process
  still surfaces its actions. `retryRevoke`/`cancelRevoke` no longer REQUIRE a lease — they use one
  when this process still holds it, and `cancelRevoke` clears the durable intent first, bailing out
  (both fences intact, message to the user) if that clear throws.

### New

- **`ClientKeyID`** — a thin alias/newtype over the existing `SHA256(pubkey)` hex string
  (`PairingStore.deviceID`, `PairingStore.swift:90`). No new derivation.
- **`AdmissionTicket`** — an immutable value `(keyID: ClientKeyID?, generation: UInt64)`, captured at
  authorization, carried by-value through register + recheck (the whole point of finding 1).
- **`SessionCapability`** (§4) — a per-session "may this session still act" flag, checked
  synchronously at each **irreducible** effect boundary and withdrawable synchronously by
  teardown/revoke. Pattern to mirror: `InputInjector`'s lock-guarded authority flag
  (`InputInjector.swift:16–29`) — but **per-session**, not the process-wide `paused`. TWO locks (Sol
  review C1): a `flagLock` guarding the flag and an `effectLock` held for an effect's duration.
  Exposes `isValid` (read), `markInvalid()` (**non-blocking** — no NEW effect can start after it
  returns), `drainInFlightEffect()` (**blocking** — waits out an already-in-flight effect),
  `invalidate()` (mark then drain, for single-session terminal paths), and
  `perform(_ effect: () -> Void) -> Bool` (fast reject, then under `effectLock` re-check the flag and
  run `effect`; returns whether it ran). Lock order is one-directional — `perform` takes
  effect→flag, nothing takes flag→effect — so there is no deadlock. `perform` is for **strictly
  synchronous, irreducible** effects only — no `await`, no reentrant capability call, no compound
  multi-OS-effect closure (§10 R2).
- **`SessionCapabilityBox`** (Sol review I3) — a lock-guarded slot letting `serve`'s cancellation
  handler reach the capability created inside `serveSession`, so a shutdown MARKS before it closes
  the transport. Remembers a cancel that fires before publication and applies it to whatever is
  published later.
- **`RevokeLease` / `RevokeReceipt`** (H-c, M-b) — `RevokeLease` is an opaque comparable token minted
  by `beginRevoke` and required by `endRevoke`/`cancelRevoke`. `RevokeReceipt` is the public value
  `beginRevoke` returns (`lease` + `evictedCount`); it lets `HostAppModel` drive end/retain/cancel
  without touching the private `Session`/`OutboundLane`.
- **Per-key generation + `RevokeLease`-fence state in `HostControl`** (§3) — in-memory, single-process,
  guarded by the existing lock. Not durable; re-enrollment (a `PairingStore` write) deliberately does
  **not** reset the generation.
- **`WindowLease`** — *CONFIRMED, unchanged (§6a).*
- **Separate lastSeen keychain item** (§6c, H-a) — `[ClientKeyID: Date]`, its own
  `service`/`account`, mutated only by `touch`/`enroll`/`revoke`-cleanup. Never gates authorization.
- **Separate revocation-intent keychain item** (§6d, Sol review I5) — `Set<ClientKeyID>`, its own
  `service`/`account` (`KeychainRevokeIntentStore`, mirroring the lastSeen split), written only by
  `revoke` (record, then clear on success), `enroll` (clear — an attended re-pair supersedes) and
  `cancelRevocationIntent`. Unlike lastSeen it DOES gate authorization: a recorded intent denies its
  key. Read fail-closed (an unreadable/undecodable item authorizes nobody), warm-cached for
  mid-session keychain-lock resilience exactly like the authorization item.
- **Menu-bar "Paired devices" view** — render `enrolledDevices` (name + fingerprint + lastSeen) with
  a Revoke button per row, gated per product-decision 1; a durable-failure row shows Retry / Cancel.
  Mirror `MenuBarHostView.enrollmentPromptView` (`MenuBarHostView.swift:153`) for layout + the
  LAContext-gated button; mirror `pairingSurface` (`:98`) for placement. Fingerprint only, never raw
  `publicKey` bytes.

---

## 3. The generation / epoch model (the crux) — ticket captured at AUTHORIZATION

*CONFIRMED sound in the re-review; unchanged from v2.*

**Problem.** `ClientKeyID` K = `SHA256(pubkey)` is stable for a device's whole lifetime. Revoke K →
re-enroll the *same* device (attended, same keypair, same K) → a new live session opens under the same
K. Revoke's teardown is asynchronous. Any recheck that reasons about "sessions under K" cannot, from
identity alone, distinguish the session it was asked to kill from a later session the owner
deliberately re-created. A monotonic generation encodes "revoked-since-admission," which identity
cannot.

**Why v1 was wrong (finding 1).** v1 stamped `session.admittedGeneration = currentGeneration[K]` **at
register**. But authorization happens far upstream, in `serveAuthGate` (`authorizedClient`,
`HostRunner.swift:851`), and register is reached only after the enrollment ceremony, scaffolding, and
`ServerHello`. Timeline that defeats v1:

| t | event | `gen[K]` |
|---|---|---|
| t0 | session authenticates (authorizedClient true) | 0 |
| t1 | revoke(K): bump | 1 |
| t2 | re-enroll K (attended) | 1 |
| t3 | session finally reaches register → v1 stamps `gen[K]` = **1** | 1 |
| t4 | recheck: `admittedGen(1) == currentGen(1)` ∧ isAuthorized → **PASSES** | 1 |

The session's admission *predates* the revoke, yet it survives — because the stamp was read at
register (post-bump), not at authorization (pre-bump).

**v2/v3 mechanism — capture at authorization (Order-A).** The generation is captured as part of the
**immutable ticket**, inside `serveAuthGate`, in this order:

1. verify the challenge signature (proves the peer holds K's private key);
2. `K = deviceID(pubkey)`;
3. `ticket = control.admissionTicket(for: K)` — reads `generation[K]` and the fence, **before** step 4;
   fence-hit → reject;
4. `record = pairings.authorizedClient(K)` — the durable check; nil → unknownKey/rejected.

Re-running the timeline: at t0, step 3 reads `gen[K] = 0` → ticket `(K, 0)`. The revoke at t1 bumps to
1. At register, `admittedGen(0) != currentGen(1)` → **DEAD**. Fixed.

- **On register:** the fence + `ticket.generation == currentGeneration[K]` check (no re-stamp).
- **On beginRevoke(K):** `generation[K] += 1`; target every session in `byClient[K]` (all stamped an
  older generation); invalidate + evict them.
- **On recheck:** `isAuthorized(K)` (durable backstop) + the **post-await capability recheck** (H-e).

**Order-A residual (the gen-read↔authorizedClient window).** Between step 3 and step 4 a revoke+re-enroll
could interleave: step 3 reads `gen = 0`, then revoke bumps to 1 and re-enrolls, then step 4's
`authorizedClient` sees the re-enrolled K as authorized → ticket `(K, 0)` → register `0 != 1` → the
session is killed and must reconnect. This is the **safe, conservative direction** (CONFIRMED R6): a
handshake that straddles a revoke→re-enroll is forced to reconnect and establish a clean session under
the new enrollment, rather than silently surviving.

**Walkthrough (revoke racing re-enroll, register-time):**

| t | event | `currentGen[K]` | live under K |
|---|---|---|---|
| t0 | X enrolled; S1 authenticates, ticket `(K,0)`, registers | 0 | {S1@0} |
| t1 | `beginRevoke(K)`: fence K (lease L), bump, invalidate S1, evict | 1 | {} |
| t2 | durable `pairings.revoke(K)`; `endRevoke(L)` lifts fence | 1 | {} |
| t3 | X **re-enrolls**; S2 authenticates, ticket `(K,1)`, registers | 1 | {S2@1} |
| t4 | a delayed re-read of `byClient[K]` still targets `gen<1` | 1 | {S2@1} |

S2 (`admittedGen 1 == currentGen 1`) is valid and was never in the t1 target set. The generation makes
revoke **irreversible for any session admitted at or before the revoke**.

**Concurrent legitimate sessions under one key** (finding 1's set requirement): both capture the same
generation and both sit in `byClient[K]` (a set); one `beginRevoke` bump targets both; a reconnect
registers a distinct SessionID under the same K, and `deregister` removes precisely by SessionID.

---

## 4. The revoke primitive: Invalidate-First, out-of-lock, discard-not-drain, outbound in the boundary

Five composed layers close the windows through which post-revoke (or post-teardown) input could execute
or through which output could still be sent (findings 3, 4, 7; H-b, H-d, H-e).

**0. Invalidate-Capability-First — the named invariant (H-d).** On **every** path that ends a session's
authority, the capability is withdrawn **before** any async teardown (bye / close / finish) — and,
on the single-session paths, before the registry removal too. The batch paths snapshot + unlink
under the lock first because H-b forbids waiting there (§1a step 3 states the ordering and why it is
still Invalidate-First; §7 invariant 1 restates the invariant to match). The enumerated paths:

| Terminal path | Where withdrawal lands |
|---|---|
| Normal serve-loop teardown | `invalidate()` (mark+drain) as the **first** statement of the `serveSession` defer (before `clipboard.stop`, `deregister`, cancels) |
| **Cancellation-driven shutdown** (Stop Hosting / listener cancel) | `serve`'s `onCancel` → `cancelServe`: `markInvalid()` on the session's `SessionCapabilityBox` **before** `connection.close()` (Sol review I3) |
| Register rejected (fence/gen) | `invalidate()` in the self-close guard, step 6, before return |
| Post-await recheck fails (H-e) | `invalidate()` in the recheck guard, step 6, before `deregister` |
| `beginRevoke` | out-of-lock, **mark all → drain all**, before any `finish`/`closeDiscardingInbound` |
| `evictLegacyAdmitted` | out-of-lock, **mark all → drain all**, before any `finish`/`closeDiscardingInbound` |
| `disconnectAll` | out-of-lock, **mark all → drain all**, before any graceful-`bye` Task |

The shutdown row is Sol review I3: `serve`'s cancellation handler used to `connection.close()` while
the capability was still valid (it was invalidated only later, in `serveSession`'s defer), so an
already-dequeued `.typeText` kept posting its remaining CGEvents past the shutdown boundary — the
synchronous injection loop never observes task cancellation. The handler MARKS (never drains): it
runs synchronously on the cancelling thread, which a stalled effect must not be able to wedge. The
`SessionCapabilityBox` also remembers a cancel that fired *before* the capability existed (during
the auth gate), so the session can never come up live on an already-cancelled serve task.

v2 invalidated only on the revoke path, so a deferred effect (`ClipboardSync.applyRemote`'s MainActor
task, `:36`) captured on a *normal* disconnect saw a still-valid capability and mutated the pasteboard
after teardown. Invalidate-First makes the deferred `perform` fail closed on every exit.

**1. Synchronous invalidation at each IRREDUCIBLE effect boundary (finding 3, H-b).** A single
top-of-loop guard is not enough (the guard releases its lock before dispatch) and a whole-message
`perform` is too coarse (a 16 MiB `.typeText` would hold the capability lock across millions of
CGEvents, starving `invalidate` — H-b). v3 checks the capability **atomic with each irreducible OS
effect**:
   - input: `capability.perform { self.postEvent(event) }` **per CGEvent**, at `InputInjector`'s
     `postEvent` seam (`:35`) — not around the whole `.typeText`;
   - file: `fileReceiver.offer/chunk` called UNWRAPPED — FileReceiver self-guards **four** boundaries
     (Sol review I4b): `offer`'s `createFile`, `chunk`'s `handle.write`, `chunk`'s finalizing
     `handle.close` (a zero-length final chunk skips the write branch entirely and used to complete
     the transfer ungated), and `dropTransfer`'s close+unlink (the quota branch reached an unguarded
     **file deletion**). The drop's close+unlink is one boundary on purpose — the pair must not be
     split, since unlinking a still-open handle or closing without unlinking each leaves a
     half-dropped transfer. A refused gate leaves the transfer in flight; the serve defer's
     `cancelAll` reclaims the handle;
   - clipboard: inside `applyRemote`'s MainActor task, `capability.perform { pasteboard.clearContents();
     pasteboard.setString(text, .string); … }` around the **one** pasteboard mutation.
   `perform` holds the **effect** lock across the (bounded) effect and re-checks the flag under it;
   `drainInFlightEffect()` takes that same lock, so each effect runs fully or is skipped, and anything
   that queued behind an in-flight effect observes the mark instead of running. Because the boundary is
   irreducible, a drain waits **at most one** such effect, whatever the message size — and the mark
   that precedes it **never waits on an effect** (it takes only `flagLock`, which is never held across
   an effect; it is an uncontended-in-practice lock acquisition, not a wait-free operation — "does not
   wait for an effect", not "cannot wait at all", Sol re-review C1).

**1b. Host-local session-control effects gate at their OWN effect boundary too (Sol review I4a,
re-review I4; R9).** The serve loop's `.startSession`/`.switchDisplay` (build a `CaptureEngine`, swap
the injector/capture, start the video task), `.viewport` (re-crop the live capture), `.clientFeedback`
(steer the encoder) and `.requestKeyframe` branches mutate HOST-side session state rather than
sending, so the outbound gates of §4.5 never covered them: an R9 residual message could reconfigure —
or START — screen capture for an already-revoked peer.

The **first** fix put an `isValid` check on the branch (`HostRunner.applySessionControl`). That was
check-then-use around an ASYNC effect and did not hold: every one of these effects is separated from
its branch by at least one suspension (`display(forID:)`'s registry read, `CaptureEngine`'s
`AsyncGate.enter()`, the `ViewportState` actor hop), the check was not coupled to `effectLock`, and
`drainInFlightEffect()` therefore returned immediately while such an effect was in flight. A revoke
landing in the gap still applied a withdrawn peer's crop and still let capture START.

v3 pushes each gate DOWN to the irreducible boundary, so no suspension separates the check from the
privileged call and every one of them is drain-coupled. `applySessionControl` is **deleted**; each
unit self-guards and the serve loop calls it UNWRAPPED (the `FileReceiver` idiom):
   - capture start: `CaptureEngine.start` issues `SCStream.startCapture` inside
     `capability.perform`; `pumpVideo` propagates its `false` and never enters the frame loop. The
     serve branch additionally wraps the synchronous `startVideo` scaffolding build in `perform` (a
     second, independent gate — scaffolding for a withdrawn peer is never even built);
   - live re-crop / fps retarget: `CaptureEngine.setViewport` / `setMaxFPS` mutate the shared
     `SCStreamConfiguration` **and** issue `updateConfiguration` inside ONE `capability.perform`. This
     is possible because the **completion-handler** form of the call is synchronous to *issue* — only
     the OS's own completion runs later — so the async form's suspension is kept out of the critical
     section. A refused gate mutates no field and issues nothing;
   - keyframe request: gated INSIDE the `ViewportState` actor (`requestKeyframe(gatedBy:)`),
     synchronously with the write, i.e. after the hop a caller-side check could not span;
   - encoder feedback: `ClientFeedbackHolder` self-guards its one irreducible write.
   A branch-level `isValid` survives only as a cheap early-out (top of `setViewport`/`setMaxFPS`,
   `start`), never as the only gate.

**2. Size caps so the pre-invalidate work is bounded too (H-b).** At the serve-loop boundary, before
dispatch, each privileged inbound message is capped by type: `.typeText` well under
`Frame.maxBodyLength` (16 MiB), inbound clipboard = `Frame.maxClipboardBytes` (1 MiB), `.fileChunk`
≈ the 64 KiB sender chunk. An over-cap message is skipped (never truncated), mirroring the existing
outbound clipboard cap (`HostRunner.swift:621`). This bounds the *count* of irreducible effects an
attacker can queue per message, so even the work done *before* `invalidate` wins the lock is bounded.

**3. `beginRevoke` never waits on an effect under `HostControl.lock` (H-b).** Under the lock,
`beginRevoke` only bumps the generation, sets the lease-fence, snapshots the target capabilities, and
unlinks the sessions (all O(sessions), no blocking calls). It **releases the lock**, then invalidates
each snapshot (the only place a bounded wait can happen) and tears the transport down. The fence stays
set under the lock for the whole operation, so new registration for K is blocked without holding the
lock across the invalidation wait. `disconnectAll` and `evictLegacyAdmitted` use the same
snapshot-under-lock / invalidate-out-of-lock shape.

**4. Discard-not-drain, terminalized before cancel (finding 7).** `InboundBuffer.finish()` (`:153`)
leaves buffered messages to drain via `next()`. `finishDiscardingBuffered()` clears all three lanes
under the lock before finishing, so the **buffered backlog** (a peer's queued frames sitting in the
lanes) is dropped — `next()` returns `nil`, never a backlogged message. `enqueue` now returns a
**terminal verdict** (`.droppedFinished` when `finished`), and `closeDiscardingInbound` terminalizes
the buffer **before** `connection.cancel()`, so once the discard runs every subsequent enqueue drops
and the receive loop **cannot re-arm** (`receiveNext` returns on `.droppedFinished`, minor). The
security-critical seam for the backlog. **Honest bound (parked-waiter residual, below):** a *single*
message whose `enqueue` wins the lock the instant before the discard, while a consumer is parked in
`next()`, is handed to that parked continuation before `finishDiscardingBuffered` runs — the
continuation resume escapes the lock. This is ≤1 message (after `finished`, all enqueues drop), not
the backlog, and is caught downstream by layer-1 (the capability guard at the effect boundary).

**5. Outbound inside the capability boundary, including direct sends (finding 4, H-e).** v1's "all cut
immediately" was false for outbound. v3 brings every producer inside the boundary:
   - `pumpVideo`/audio/stats check `capability.isValid` **immediately before each post-encode send**
     and drop when invalid (`:1029/:1098/:1118`);
   - the `OutboundLane` sink gates on `capability.isValid` before `connection.send` (`:108–110`), so a
     taken-but-not-sent message is dropped;
   - `HostLaneRouter.send` gates on the capability; the serve defer calls `router.closeBoundLanes()`
     which **terminalizes** (`closed` flag) and closes the retained secondary streams — a **late bind
     racing closure is refused** (H-e);
   - the **direct** handshake sends that bypass the lane — `ServerHello` (`:703`), initial
     lock-status (`:714`), pong (`:747`) — each get an `isValid` pre-check (H-e);
   - revoke/teardown call `session.outbound.finish()` synchronously **after** invalidation.

**Defined bounded residual (§10 R3, R8, R9).** Three irreducible-size residuals remain, all bounded
and of the same class:
   - **Parked-waiter single message (R9, Task-2 finding):** as §4.4 above — a lone message racing the
     discard while a consumer is parked in `next()` can be handed to that continuation before the
     discard clears (the resume escapes the lock; empirically ~1% of a forced simultaneous race, and
     mutual exclusion cannot make the discard an unconditional winner of a truly concurrent single
     enqueue). Bounded to **one** message (post-`finished`, all enqueues drop); it is NOT the buffered
     backlog (100% cleared). Backstopped by **layer-1** — the capability guard at the effect boundary
     (§4.1) drops the effect even if the message reaches the serve loop. Do NOT trade the direct
     discard's ~99% win-rate for queue-serialization: that is empirically worse (~46%) and slower, and
     still cannot win a simultaneous race.
   - **In-flight transport bytes:** bytes already accepted by `Network.framework` for a `send` cannot
     be recalled. `isValid`-then-async-`send` is not atomic (a send cannot run under the sync `perform`
     lock — R2), so a direct send whose `isValid` check just passed may still put one frame on the
     wire. `closeDiscardingInbound` + `closeBoundLanes` reclaim the streams promptly, dropping
     undelivered bytes.
   - **Out-of-lock mark window (R8):** because withdrawal moves out of the lock (H-b), there is a
     brief interval between the under-lock snapshot/unlink and the out-of-lock **mark pass** during
     which one already-in-flight irreducible `perform` (or one queued deferred MainActor pasteboard
     write) can still execute. This is **one irreducible effect per capability**, the same bounded
     class as the transport residual — not an unbounded stream. The security line holds because (a)
     the fence already blocks *new* admission for K, (b) the buffer is discarded so no *further*
     inbound is dispatched, (c) size caps bound that one effect, and (d) the mark pass is
     non-blocking, so ONE session's stalled effect cannot extend any *sibling's* window.
   The honest guarantee: **no NEW effect on a capability after `markInvalid()` returns; ≤ one
   already-in-flight irreducible effect per capability, plus bytes already handed to the transport.**

**No graceful `bye` on revoke (unchanged).** `closeDiscardingInbound()` cancels the transport with no
farewell frame. `disconnectAll` (`HostControl.swift:120`) sends `bye` first *by design* (trusted
client); revoke must **not** — a de-trusted peer loses access at once, and a `bye` both delays the cut
and (client-side) suppresses the reconnect we no longer owe it. Matches han.3's no-oracle stance
(decisions.md 2026-07-23 item 4).

**Ordering within revoke:** (under lock) bump + fence + snapshot + unlink + keepAwake-end → (out of
lock) `markInvalid()` on **all** snapshots → `drainInFlightEffect()` on **all** snapshots → per
snapshot `outbound.finish()` → `closeDiscardingInbound()`. Never close-then-invalidate: the transport
close alone drains, so withdrawal must land first. Never drain-before-marking-the-others: that is the
C1 defect (one stalled effect leaves every sibling under the key fully live).

**Reachability caveat (finding 2, honest framing).** The "queued enrollment interleaving a revoke"
that finding 2 fixes is *hard to reach* via the normal ceremony: an enrollment for K only runs after
the user's attended LAContext approval, and the ceremony enrolls a key that became *unknown* — which
only happens after a durable removal. So the durable revoke and a same-K re-enroll are naturally far
apart in wall-clock and serialized by the PairingStore actor. v3 keeps the lease-fence anyway: it is
the *correct* linearization, it is cheap, and it converts every racy interleaving (reachable or not)
into a fail-closed reject-and-reconnect rather than a wrong kill or a wrong admit.

---

## 5. The admission-TOCTOU fix (reserve → register → recheck → post-await recheck)

**The hole** (decisions.md 2026-07-22 han.1 "HIGH atomic admission-vs-revocation", re-activated by
han.3): between the gate's authorization (`serveAuthGate`'s `authorizedClient`, `HostRunner.swift:851`)
and `control.register` (`:709`), a revoke can land. The session registers for a now-revoked key; the
revoke's live-kill already scanned `byClient` and found nothing → it streams unrevoked. **v1 compounded
this** by leaving register downstream of the outbound producers (finding 5) — clipboard could be *sent*
before the recheck even ran. **The re-review (H-e) found one more gap:** the durable recheck is an
`await` that suspends, and v2 resumed straight into scaffolding/`ServerHello` with no re-guard.

**The v3 fix, four composed guarantees** (§1b reorder + §3 ticket + §4 fence + the post-await recheck):

- **Ticket captured at authorization (§3).** Immutable `(K, generation)` — reflects the authorization
  instant, not register.
- **Fence + generation check *in* register (synchronous, under the lock).** `guard revoking[K] == nil
  && ticket.generation == currentGeneration[K]`. The primary mechanism; rejects any session whose key
  is mid-revoke or whose admission predates a bump.
- **`isAuthorized` recheck after register (durable backstop, keyed sessions only).** Defense-in-depth
  for the "revoke fully completed before this session registered" shape.
- **Post-await capability recheck (H-e).** The instant the durable `await` returns — **before**
  `didBuildScaffolding`, lane authorization, `ServerHello`, and any producer — re-read
  `capability.isValid`. A `beginRevoke` that landed *during* the suspension invalidated the capability
  synchronously (the live-authority signal), so this recheck catches it even if the durable
  `isAuthorized` read had already returned stale-true. Fail → terminalize (Invalidate-First,
  deregister, discard-close), no `ServerHello`, no producers.

Every interleaving resolves:

- **revoke fully before ticket capture:** `authorizedClient` returns nil → not authenticated → no
  ticket, no register.
- **revoke's begin between ticket capture and register:** register's fence (`revoking[K] != nil`) **or**
  generation check rejects → Invalidate-First self-close, no producers, no `ServerHello`.
- **revoke's begin during the durable `await`:** the **post-await capability recheck** sees the
  synchronously-invalidated capability → terminalize before any producer/`ServerHello`.
- **revoke's begin after producers start:** the session is in `byClient[K]`; `beginRevoke`'s snapshot
  finds and invalidates it → the irreducible effect-boundary guards drop subsequent effects and the
  discard-close tears it down.
- **revoke→re-enroll before register:** ticket carries the *pre-bump* generation (Order-A) →
  `ticket.gen != currentGen` → rejected → reconnect → admitted cleanly under the new enrollment.

**Serialization note (findings 2, 3; H-b).** The two authorities are the shared `PairingStore` actor
(durable) and `HostControl` (live sessions + generation + lease-fence). They are **ordered inside one
revoke operation and fenced by a lease**, not co-locked and not two independent writes. The
lease-fence globally blocks admission for K for the whole span of the operation (retained on durable
failure — H-c); the live-kill/register race is resolved inside HostControl's single lock; and the
invalidation that could *wait* is moved out of that lock (H-b) so revoke can never freeze registration.
Legacy sessions (nil key) skip the keyID recheck and stay governed by `evictLegacyAdmitted`.

---

## 6. The three folded cleanups (with findings 6, 9; H-a)

### 6a. Full window binding of the SAS lease + `.sasCode`/`.sasConfirmed` + `isPairing` — opaque lease (finding 9)

*CONFIRMED, unchanged from v2.* `openWindow` mints a fresh `WindowLease` id in the limiter
(`SASAttemptLimiter.open`, `:30`). `registerAttempt` (`:89`) returns the current `WindowLease?` (nil
when closed/over-cap). The preamble carries that lease **unchanged** through `claimCodeDisplay(lease:)`
(which validates the lease is the current open window's, not merely that the slot is free),
`holdsCodeDisplay`, and the `.sasCode`/`.sasConfirmed` emissions (each stamped with the lease).
`HostAppModel` tracks the current `WindowLease` and applies `displayedSASCode`/`clientConfirmed` only
when the stamp matches — so a prior window's async event can never mutate a newer window's HUD. Composes
with the existing `windowTransition` serialization (`HostAppModel.swift:57`, commit de3a447): the lease
is the value that transition mints/retires.

### 6b. Attempt-scope the host decision flags — per-task tokens, reject duplicates (finding 9c)

*CONFIRMED, unchanged from v2.* Keep `decisionsInFlight: [UUID: DecisionToken]` (attemptID → the
single in-flight decision's opaque token). `approveEnrollment(attemptID)` / `denyEnrollment(attemptID)`:
`guard decisionsInFlight[attemptID] == nil else { return }` (**reject the duplicate start — do not
launch a second LAContext**); mint a token, store it, and in the Task's `defer` clear the entry **only
if it still holds this token** (a stale task never clears a newer one). The popover's button-disable
derives from `decisionsInFlight[shownAttemptID] != nil`. The `.enrollmentResolved` correlated-clear
(`:371–399`) narrows to the resolved attemptID's token.

### 6c. Cross-process semantics — the `touch` resurrection fix, separated lastSeen (finding 6, H-a)

The app and CLI share **one** pairings keychain item but hold **per-process** `PairingStore` actors with
independent warm caches and **separate** `HostControl` registries. A revoke in the app process kills
live sessions **in the app process only** and updates the durable keychain item.

**Finding 6 (v2) — the durable claim was false.** Every authenticated handshake calls `pairings.touch`
(`HostRunner.swift:857`), and `touch` (`:156–162`) read the **warm cache** via `mutableState` and
re-persisted the **whole map** — durably resurrecting a revoked key.

**H-a — v2's cache-bypass read was NOT sufficient.** Making `touch` re-read the durable set before
writing does not close the race, because the read-modify-write of the *whole* map has **no
cross-process CAS**. Verified against `readPersisted`/`persist` (`:193–208`): each is a whole-blob
read / whole-blob write. The lost-update interleaving:

| t | app process | CLI process (warm) |
|---|---|---|
| t0 | | `touch(K)`: cache-bypass read → map **has K** |
| t1 | `revoke(K)`: write map **without K** | (paused mid-touch) |
| t2 | | `touch(K)`: write its t0 snapshot → map **has K again** |

`SecItemUpdate` prevents a *torn* blob but gives no compare-and-swap, so the CLI's later write clobbers
the app's revoke. `touch` — a cosmetic lastSeen bump — must never be able to rewrite the authorization
set.

**Fix (H-a) — separate the lastSeen storage.** `lastSeen` moves out of the authorization blob into its
own keychain item (`[ClientKeyID: Date]`, distinct `service`/`account`, mirroring `KeychainPairingStore`
at `:214`):
1. The authorization item (`Persisted.clients` + `migrationComplete`) is mutated **only** by `enroll`
   and `revoke`. `touch` never touches it.
2. `touch(id:)` reads-modifies-writes **only** the lastSeen item (best-effort; a locked keychain
   no-ops). It **cannot** re-add a key to the authorization set — the invariant holds *by construction*,
   not by a hoped-for read ordering.
3. `enroll` seeds `lastSeen[K] = now`; `revoke` best-effort deletes `lastSeen[K]`.
4. `list()` reads the authorization item for **which** devices exist and joins the lastSeen item
   (default → `enrolledAt` when absent); it may prune lastSeen keys absent from the auth set.

This turns §6c's semantic from "the CLI resurrects K durably" into "the CLI can never rewrite the
authorization set from a lastSeen bump." It is still **not** a synchronous cross-process live kill: the
*current* CLI handshake already passed authorization against its stale cache before `touch` runs, so
that one session proceeds; a warm CLI still authorizes K until its cache goes cold or it re-reads the
authorization item (the app-shared instance gets synchronous live invalidation). han.4 continues to
make **no claim of cross-process live invalidation** (that needs a shared IPC authority or a
cache-invalidation signal — out of scope). The revoke UI copy stays honest: revoke is authoritative for
the process that owns hosting (the app, `HostRunner.swift:66`), not a fleet-wide kill switch.

**Documented fallback — non-persisting `touch`.** If the second keychain item is judged not worth its
weight, `touch` may instead keep `lastSeen` in an **in-memory-only** per-process overlay (never
persisted), with `list()` overlaying it on the durable `enrolledAt`. This also makes `touch` unable to
rewrite the authorization set, at the cost of a `lastSeen` that does not survive a restart and is not
shared across processes. Separate storage is preferred (it preserves the durable, cross-process
`lastSeen` the UI shows); non-persisting is the smaller-surface fallback.

### 6d. Durable revocation intents + fresh-read mutations (Sol re-review C2 + I5)

Two durability defects in the *store* underneath the (correct) revoke sequence.

**C2 — the mutation path wrote from a stale cache.** `mutableState()` returned the warm process-local
cache whenever it had one and read the keychain only when cold, so `enroll`/`revoke` — which
read-modify-write the WHOLE map — could persist an arbitrarily old snapshot:

| t | P1 (app) | P2 (CLI, warm on {K, J}) |
|---|---|---|
| t0 | warm on {K, J} | warm on {K, J} |
| t1 | `revoke(K)` → writes **{J}** | |
| t2 | | `revoke(J)` → writes its stale **{K}** — K is back, durably, and both calls returned success |

An unrelated `enroll(X)` in P2 does the same (writes {K, J, X}). §9 accepted last-writer-wins on a
**fresh read**; this was last-writer-wins on an **arbitrarily old snapshot**, which is strictly wider.
**Fix:** `mutableState()` (and the intent-set equivalent) ALWAYS re-reads the durable item and
propagates a read failure — a mutation never starts from a partial/empty/stale state. The
authorization READ path keeps its warm cache deliberately (a keychain that locks mid-session must not
brick a live host; a stale ALLOW there is bounded by the fence and the intent, while a stale WRITE is
permanent). **Honest bound:** this narrows the window to the actual read-modify-write; it does NOT make
the RMW atomic. A genuine cross-process CAS is out of scope for this wave — bead `portview-auf` (§9).

**I5 — "fail closed" held only for the current process lifetime.** §1a step 5 claimed that when the
durable `pairings.revoke` throws, the retained fence leaves K unauthorizable. `HostControl` is built in
memory (`HostAppModel.swift:61`) and `revokeFailures` is an in-memory dictionary (`:134`), so nothing
durable recorded the revocation INTENT before the removal was attempted:

`beginRevoke(K)` kills live sessions and fences K → `pairings.revoke(K)` throws (record still in the
keychain) → the app crashes / is quit / the Mac restarts before Retry or Cancel → the next process has
a fresh `HostControl` with no fence, an empty `revokeFailures`, and the authorization record intact →
K's next signed handshake is **admitted at generation 0**. The user asked to revoke, the UI said
"incomplete", and a restart silently re-admitted the device with no trace.

**Fix — a third keychain item holding pending revocation intents** (`Set<ClientKeyID>`, own
`service`/`account`, mirroring §6c's split so an intent write is never an RMW of the authorization
set):

1. `revoke(K)` records the intent **before** any removal attempt — before the fresh authorization read
   too, so a revoke that cannot even READ the authorization item still leaves a durable fence.
2. While K's intent is recorded, `isAuthorized(K)` / `authorizedClient(K)` are **false** even though
   K's record still exists. This is what makes the step-5 claim true across a restart.
3. The intent is cleared **only** on a durably-successful removal (or when K turns out not to be
   enrolled — nothing to complete). **Stated precisely (Sol re-review):** a revoke that succeeds
   *attempts* the clear; the attempt is best-effort, so what a successful revoke guarantees is that K
   is gone from the authorization item, **not** that no intent is left. A clear that fails leaves an
   inert orphan — see the Residual below and item 8.
4. `list()` remains the INVENTORY view and still shows an intent-fenced device (it IS still enrolled),
   with `pendingRevocations()` marking which rows are mid-revoke — so a fresh launch renders the
   "revoke incomplete" row with **Retry** (re-attempt the removal; no lease needed) and an
   **LAContext-gated Cancel** (`cancelRevocationIntent`, deliberately re-admitting the still-enrolled
   key). Where the in-process lease still exists it is used exactly as before. `pendingRevocations()`
   returns `PendingRevocations.unreadable` — NOT an empty set — when the intent item cannot be read,
   because authorization fails closed on that same read: reporting "nothing pending" while nothing is
   authorized is the reassuring-direction lie this whole item exists to eliminate.
5. Intent recording does not ABORT the revoke — if the intent item cannot be read or written the
   removal is still attempted (no worse than before) — but the outcome is **reported, not swallowed**
   (Sol re-review). When the removal then fails, `revoke` throws one of **three** cases and the app
   renders all three differently (§1a step 5). The classification is by what the item **proved**, and
   `recordRevocationIntent` returns exactly that (`IntentDurability`):
   - **read ok + id present (already, or after a successful write)** → `.fencedDurably`.
   - **read ok + id absent + write failed** → `.notDurable`. Absence is *proven*; only here may the UI
     state re-admission categorically.
   - **read failed** → `.durabilityUnknown`. Nothing was written and nothing is known; an earlier
     attempt's durable intent may still be sitting in the item denying K (Sol pass 3 N1). Reporting
     this as `.notDurable` was a false statement, not a conservative one, and it contradicted a
     last-known pending set that still listed K.

   The correlated both-writes-fail case is the one the earlier best-effort code reported as a clean
   fenced-incomplete while a restart re-admitted K; it cannot be fixed by writing elsewhere, so the
   contract is the loud report plus a Retry that **re-attempts the intent write every time**, so a
   transient failure self-heals into a durable fence. A read failure still writes nothing (a
   lone-entry write would drop another key's intent and thereby re-admit it) — which is exactly why
   it can only ever be reported as *unknown*.
6. `enroll` clears a pending intent for the key it enrolls: an attended, LAContext-gated re-pair is an
   explicit decision to admit, so a wedged revoke can never permanently lock out a device the owner
   just re-paired in person.
7. Fail-closed reads: an unreadable or undecodable intent item authorizes **nobody** (symmetric with an
   unreadable authorization item, which already denies everyone); once read successfully the set is
   warm-cached, so a mid-session keychain lock does not brick a live host.
8. **`enroll`'s clear THROWS; it is not best-effort** (Sol re-review, enroll-false-success). Because
   the authorization view subtracts the intent set, an intent that cannot be re-read or re-written
   leaves the key that was just enrolled **unauthorizable** — and the best-effort version let
   `runEnrollmentCeremony` emit `.enrollmentResolved(approved: true)` for exactly that device, so the
   UI claimed an authorization outcome the gate then refused. `enroll` now throws
   `PairingStoreError.enrollmentStillFenced`, which `runEnrollmentCeremony` already handles by failing
   closed (no ServerHello, no scaffolding). The authorization record stays written — the clear is
   deliberately ordered after `persist` — so the device keeps a visible row to Cancel or repair from
   rather than vanishing.

   8a. **…and that throw is now fail-closed IN THIS PROCESS TOO (Sol pass 3 N2).** The throw alone was
   not enough. Interleaving: `intentCache` is warm at `[]`; the intent item then goes unreadable while
   the authorization item stays writable; `enroll` persists K (warming the *authorization* cache) and
   its fresh intent read throws, so it throws `enrollmentStillFenced` and the ceremony emits
   `approved: false` and closes the connection — but K's **next** signed handshake hit `authorizedMap`,
   which subtracted the still-warm **empty** intent set from an authorization cache now containing K,
   and **admitted K**. Not an unapproved-key bypass (the owner did approve the ceremony) and distinct
   from the routed `portview-oj5` repair UI — but the operation reported failure and the key worked,
   which contradicts the thrown error, the emitted `approved: false`, and this section's own claim.
   `enroll` now inserts the id into a process-local `unverifiedIntentFence` before throwing;
   `authorizedMap()` subtracts that fence as well as the intent set, and `pendingRevocations()`
   surfaces it so the denial is visible rather than silent. It is lifted **only** by
   `dischargeRevocationIntent` succeeding — i.e. by a genuine read of the durable item proving the id
   carries no intent (a successful re-enroll, or the attended Cancel hatch). Deliberately a per-id
   fence rather than poisoning `intentCache`: dropping the warm cache would deny every *other* live
   device on a transient mid-session lock (the brick-a-live-host regression item 7 exists to prevent)
   **and** would still be insufficient, since a later successful read that omits the id would re-admit
   it. Ordering is unchanged and must stay so — the clear runs **after** `persist`, never before: a
   pre-clear followed by a failed authorization write would discharge a legitimate pending revoke for a
   key that is still durably enrolled, re-admitting it. Regression:
   `PairingStoreTests.aFailedEnrollLeavesTheKeyUnauthorizableEvenWithAWarmEmptyIntentCache`.
9. **Not built here: recovery from a corrupt/unreadable intent item.** With the item unreadable there
   is no in-app exit — `cancelRevocationIntent` re-reads the same broken item and throws, and `enroll`
   now (correctly) refuses. An attended, LAContext-gated store-wide repair that OVERWRITES the item
   without reading it — explicitly discarding every pending intent, i.e. re-admitting every wedged
   revoke — is bead **`portview-oj5`**. Until it lands, the recovery is manual keychain deletion, and
   the UI's job is limited to saying the store is unreadable.

**Cross-process side-effect (a bonus, still not a live kill).** Because the intent lives in the shared
keychain, the OTHER process (the CLI host) also denies K once it reads the intent item — so a wedged
revoke fails closed beyond the app process too. It is not synchronous: a CLI whose intent set is
already warm keeps serving it, so §6c's "no cross-process live invalidation" claim stands unchanged.

**Residual 1 (accepted, inert).** If the final clear fails, an ORPHAN intent for a no-longer-enrolled
key remains: it authorizes nobody (the key is gone), `pendingRevocations()` filters it out (it
intersects with the enrolled set), and the next `enroll`/`revoke` of that id discharges it. Same shape
as §6c/R7's orphan-lastSeen residual — **including the unbounded-growth part**: nothing sweeps orphan
intents either, so the item grows across revoke churn where the clear keeps failing. Cosmetic, and the
filtering keeps it inert; a sweep is out of scope for this wave alongside R7's (`portview-1z1`).

**Residual 2 (accepted, REPORTED, not fixable here) — the correlated double-write failure.** The intent
item and the authorization item live in one keychain, so the realistic failure mode breaks both writes
at once. Then nothing durable is recorded, and a restart re-admits K — which recreates the exact bug
the intent was introduced to fix. **No implementation closes this**: a denial that survives a restart
has to be *written somewhere*, and the premise is that nothing can be written (inventing a second
storage location outside the keychain trades one durability dependency for a weaker one and is
explicitly rejected). The reviewer's proposed decisive test — fail both writes, reset the injections,
construct a fresh store, assert K still denied — is therefore **unsatisfiable by construction**, and
chasing it would only produce a fake mechanism. What IS required, and is implemented and tested:
`revoke` distinguishes the case (`.notDurable` vs `.fencedDurably` vs `.durabilityUnknown`), the app
records it (`HostAppModel.revokeDurabilityWarnings`) and the row says *"revoke NOT saved — regains
access if Portview restarts"*, and every Retry re-attempts the intent write so a transient failure
self-heals. Regression: `PairingStoreTests.revokeSurfacesANonDurableFenceWhenTheIntentWriteAlsoFails`
(which asserts the honest re-admission outcome too) and
`…/retryRecordsTheIntentTheFirstAttemptCouldNotWrite`.

**Scope of that residual, corrected (Sol pass 3 N1).** It covers only the case where the intent item is
**readable and the write fails**. A failed *read* is NOT this residual and must not be reported as it:
nothing was written, so whatever the item already held is untouched, and an earlier attempt's `{K}`
still denies K from a cold store. That case is `.durabilityUnknown`, and its regression is
`PairingStoreTests.aFailedIntentReadReportsUnknownDurabilityNotProvenAbsence`.

---

## 7. Security invariants (must hold)

1. **Invalidate-Capability-First (H-d).** On **every** terminal path — normal serve-defer,
   **cancellation-driven shutdown**, register reject, failed post-await recheck, `beginRevoke`,
   `evictLegacyAdmitted`, `disconnectAll` — the capability is withdrawn **before any async teardown**
   (bye / close / finish / lane-close). No deferred or in-flight effect outlives a session's
   authority on any exit. Two refinements make this precise (Sol review I7 + C1 + I3), replacing the
   earlier "before any registry removal" phrasing that contradicted §1a:
   - **Single-session paths** (serve-defer, register reject, post-await recheck) call the blocking
     `invalidate()` (mark **then** drain) and do so before their `deregister`, so withdrawal there
     genuinely precedes the registry removal too.
   - **Batch paths** (`beginRevoke`/`evictLegacyAdmitted`/`disconnectAll`) snapshot and unlink from
     the registry **under the lock first**, because H-b forbids anything that can wait from running
     there (invariant 3). Withdrawal follows out of the lock as **mark-all → drain-all**, still
     strictly before any transport teardown. The unlinked-but-not-yet-withdrawn interval is closed
     by the fence (no new session for K) plus the non-blocking mark, which ends the interval for
     every snapshotted session at once — see §1a step 3 and R8.
   - **Shutdown** marks only (`cancelServe` via `SessionCapabilityBox`), because a cancellation
     handler runs synchronously on the cancelling thread and must not be wedged by a stalled effect;
     the serve defer's full `invalidate()` still runs as the loop unwinds.
2. **Effect-boundary invalidation at the IRREDUCIBLE unit, synchronous (finding 3, H-b).** Every
   privileged inbound effect is size-capped and runs through `capability.perform` at one irreducible
   effect boundary — one CGEvent post, one pasteboard write, one file **creation**, one file-chunk
   write, one transfer **finalization** (`handle.close`), one over-cap **drop** (that file's
   close+unlink, deliberately unsplit) — never a compound message, so a drain waits at most one such
   effect. Host-local **session-control** effects (capture start / live re-crop / fps retarget /
   keyframe / encoder feedback) are gated the SAME way — under `perform`, at the boundary, not at the
   serve-loop branch (Sol re-review I4). Be precise about which boundaries are synchronous-under-
   `perform` and which are not, because `perform` cannot span an `await` (R2):
   - **Synchronous under `perform`** (check and privileged call in one critical section; a concurrent
     `drainInFlightEffect()` waits for them): every CGEvent post; the pasteboard write; the four
     `FileReceiver` boundaries; `SCStream.startCapture`; the config-mutate + *issue* of
     `SCStream.updateConfiguration` (completion-handler form, so the issue is synchronous); the
     `ViewportState` keyframe write (inside the actor); the `ClientFeedbackHolder` write; the
     synchronous `startVideo` scaffolding build.
   - **NOT under `perform`, post-suspension re-check only:** the outbound `send`s (§4.5) — a transport
     write cannot run under a synchronous lock — and `admitSession`'s post-await recheck.
   - **Residual after the fix.** Two things remain, both bounded and named: (i) the OS *completes* a
     call that was already issued — `startCapture`/`updateConfiguration` finish asynchronously, so one
     already-issued reconfiguration or capture start can take effect after the mark; the drain waits
     for the **issue**, not for the OS's completion. (ii) `setViewport`'s post-success bookkeeping
     (`viewportState.set` / `setAppliedRegion`) runs after that same effect and is not re-gated — it
     is host-local frame-stamping state for an effect that was authorized when issued. Teardown stops
     the stream (`currentCapture?.stop()`) and the outbound gates keep the frames off the wire.
     **No longer a residual (Sol pass 3 N3):** `setViewport`'s tolerance-qualified **no-op** branch.
     It used to check `capability.isValid` and then hop into `viewportState` to re-stamp the region —
     a check-then-await with no effect lock, so a mark landing in the hop passed the check, a
     concurrent `drainInFlightEffect()` returned at once, and the actor resumed to mutate session
     state after withdrawal. Nor were those writes idempotent: the `< 1`-pixel tolerance admits a
     sub-pixel-different `normalizedRect`, so a peer could keep drifting the frame stamp away from the
     configuration ScreenCaptureKit is actually running. The branch now performs **no state writes at
     all** — it returns before both writes — which removes the ungated mutation *and* keeps the stamp
     equal to the applied configuration. Only residual (ii), which belongs to an operation that was
     authorized when issued, remains. Regression:
     `CaptureEngineTests.aToleranceQualifiedNoOpRecropWritesNoSessionStateAtAll`.
   Buffered inbound is **discarded, never drained**; a finished buffer drops and never re-arms the
   receive loop.
3. **Revoke never blocks the registry lock on an effect (H-b).** `beginRevoke` under `HostControl.lock`
   only bumps + fences + snapshots + unlinks; capability invalidation (which may briefly wait) and all
   transport teardown happen **out of the lock**. The lease-fence stays set under the lock for the
   whole operation.
4. **Outbound inside the boundary, including direct sends (finding 4, H-e).** Video/audio/stats/cursor/
   clipboard-send/broadcast/file producers **and** the direct `ServerHello`/initial-lock-status/pong
   sends check the capability and stop on `invalidate()`; `closeBoundLanes` terminalizes so a late bind
   cannot survive closure. The only post-revoke outbound is the bounded already-in-transport residual
   (§4).
5. **No graceful `bye` on revoke.** A de-trusted peer loses access at once and receives no
   reconnect-suppressing signal. (`disconnectAll`'s `bye` is the trusted-disconnect exception and is a
   direct send unaffected by capability invalidation.)
6. **Revoke is one linearized, lease-owned, fail-closed operation (finding 2, H-c).** `beginRevoke`
   mints an opaque `RevokeLease`, coalesces/rejects a duplicate begin, and returns a public
   `RevokeReceipt`. `endRevoke`/`cancelRevoke` require the **matching** lease. A durable-write failure
   **retains** the fence (K stays unauthorizable) with Retry + an authenticated Cancel — never a silent
   fence-lift that re-admits a still-enrolled key.
6b. **…and its fail-closed state is DURABLE — IFF the intent is recorded; otherwise it is
   process-lifetime, or of UNKNOWN lifetime, and SAID SO (§6d, Sol review I5 + re-review; three-way
   split, Sol pass 3 N1).** A revocation intent for K is recorded in its own keychain item **before**
   the durable removal is attempted and cleared only once that removal lands. Split by what each
   outcome **proves**, because both the unconditional phrasing and the later two-way phrasing were
   false — the two-way version claimed proven absence from a failed *read*, which proves nothing:
   - **Intent recorded** (item read; id already present, or the fresh write landed) → while it is
     recorded, `isAuthorized`/`authorizedClient` deny K even from a fresh `PairingStore` in a new
     process, and even though K's record still exists. So "revoke → durable write throws → quit/crash
     before Retry or Cancel" cannot silently re-admit K on the next launch. `revoke` reports this as
     `RevokeIncomplete.fencedDurably`.
   - **Item read, id absent, intent write failed too** (the correlated one-keychain case) → **nothing
     durable exists**, provably, and a restart DOES re-admit K; the in-process fence is the only thing
     holding it. The invariant here is not a denial — it is **honesty**: `revoke` throws
     `RevokeIncomplete.notDurable`, and the row must render the distinct "regains access if Portview
     restarts" copy rather than the same "revoke incomplete" the durable case shows. Silence, or a
     shared rendering, would be the original bug. Every Retry re-attempts the intent write, so a
     transient failure promotes the row to durable.
   - **Item could not be READ** → nothing was written and **nothing is known**. `revoke` throws
     `RevokeIncomplete.durabilityUnknown` and the row's copy is **conditional** ("may regain access —
     could not verify"), never categorical, and never contradicts a last-known pending set that still
     lists K (when it does, the row says only that the re-check failed). The old two-way code reported
     this as `.notDurable`, which was factually wrong: the read failure leaves an earlier attempt's
     durable `{K}` untouched, so a fresh process still denies K. It errs safe, and it is still a false
     statement — and honest reporting is the whole contract of this invariant.
   - **A successful revoke does not guarantee "no intent left"** — the final clear is best-effort and a
     failure leaves an inert orphan (§6d Residual 1, R11). What it guarantees is that K is gone from
     the authorization item.
   The incomplete state is visible to the UI (`pendingRevocations()`, which reports `.unreadable`
   rather than an empty set when the item can't be read), Retry works without a lease, and Cancel
   re-admits only by durably removing the intent (LAContext-gated). An attended re-enrollment of the
   same key supersedes a pending intent, so no wedged revoke can permanently lock out a device the
   owner re-paired in person — and if that clear cannot be made durable, `enroll` **throws** instead of
   reporting an enrollment the gate would refuse (§6d item 8) **and fences the id for the rest of the
   process**, so the key it just refused is not authorizable here either (§6d item 8a).
6c. **Authorization mutations never write from a warm cache (§6d, Sol review C2).** `enroll`/`revoke`
   and every intent write re-read their durable item immediately before the read-modify-write and
   propagate a read failure. The authorization READ path keeps its warm cache on purpose (mid-session
   keychain-lock resilience). Bound stated honestly: the RMW window is narrowed, not eliminated —
   whole-blob keychain items give no CAS (bead `portview-auf`, §9).
7. **Generation captured at authorization, monotonic per key (finding 1, CONFIRMED).** The ticket's
   generation is fixed at the authorization instant; `admittedGen < currentGen ⇒ dead`. An
   already-admitted session, once revoked, can never be resurrected by a later re-enrollment.
8. **`byClient` is a set.** Registration never overwrites a concurrent/reconnecting session under one
   key; one revoke finds **all** of the key's live sessions.
9. **`touch` can never rewrite the authorization set (H-a).** `lastSeen` lives in separate storage (or
   is non-persisting); the authorization item is mutated only by `enroll`/`revoke`. A lastSeen bump
   cannot re-add a key absent from the authorization set — by construction, not by read ordering.
   Likewise an intent write (§6d) is confined to its own item, so recording or clearing a fence can
   never add or drop an enrolled key.
10. **Admission closed under revocation, ahead of every producer (findings 1, 5; H-e).** Reserve →
    register → durable recheck → **post-await capability recheck** run before `didBuildScaffolding`,
    the outbound producers, clipboard polling, lane authorization, and `ServerHello`. A session
    admitted the instant before a revoke — or one whose durable recheck suspended across a revoke — is
    caught by the live-kill, the fence, the generation check, or the post-await recheck; it never
    streams and never *sends* unrevoked.
11. **Legacy sessions stay key-independent.** Revoke is key-scoped and never touches nil-key legacy
    sessions; `evictLegacyAdmitted` (now Invalidate-First + discard-close) governs those.
12. **Destructive-action gating is mandatory.** Revoke is gated behind LAContext
    `.deviceOwnerAuthentication` **and** a confirmation dialog (product decision 1); the Cancel escape
    hatch on a durable failure is separately LAContext-gated. Last-device revoke leaves the host
    `.required` / locked-out until an attended in-person re-pair (product decision 2).
13. **keepAwake begin/end linearized with the registry transition (finding 8).** `sessionBegan`/
    `sessionEnded`/`endAll` run **inside** the HostControl lock (HostControl→KeepAwake→IOKit order), so
    for any id `sessionBegan` strictly precedes any `sessionEnded` and a `disconnectAll` `endAll`
    cannot race a new registration's `sessionBegan` (M-a). `byClient` is cleared everywhere `sessions`
    is (register/deregister/beginRevoke/disconnectAll).
14. **Key-material hygiene.** The device list and all logs surface fingerprint / deviceID / name /
    lastSeen only — never raw `publicKey` bytes.
15. **Cross-process honesty.** No claim of cross-process live invalidation; the durable record updates,
    is never resurrected by a stale `touch` **nor by a stale-cache `enroll`/`revoke`** (§6d C2 — every
    mutation re-reads first), and is honored on the other process's next cold read. Still no CAS: two
    genuinely concurrent read-modify-writes of the authorization item remain last-writer-wins over a
    *fresh* read (bead `portview-auf`).

---

## 8. Test plan

### Pure / TDD (land with the code, adversarially reviewed pre-commit)

- **`HostControl` registry + generation + lease-fence** (extend `HostControlTests`):
  - `register` threads `ticket` + `capability`; `byClient` holds **multiple** sessions per key;
    `beginRevoke(K)` invalidates + evicts **all** of them; `endRevoke(matching lease)` lifts the fence.
  - **Ticket-at-authorization (finding 1):** a session whose ticket carries `gen=0`, registered after a
    `beginRevoke` bumped `gen=1` (even with a re-enroll making `isAuthorized` true again), is rejected
    at register (`admittedGen != currentGen`). The §3 register-time table as a test.
  - **Lease-fence (finding 2, H-c):** while K ∈ `revoking`, `admissionTicket(for: K)` returns nil and
    `register` rejects; a **second** `beginRevoke(K)` coalesces (returns the existing receipt, no
    second fence); `endRevoke` with a **stale** lease is a no-op; `endRevoke` with the matching lease
    lifts. **Fail-closed:** simulate a durable-revoke throw → the fence is **retained** (K still
    unauthorizable), Retry then success lifts, and `cancelRevoke(matching lease)` lifts without a
    durable revoke.
  - **Invalidate-First (H-d):** on a normal `deregister`-driven teardown the `capability` is
    `invalidate()`d **before** the registry entry is removed; on `evictLegacyAdmitted` and
    `disconnectAll` (batch paths, which unlink under the lock — §7 invariant 1) it is withdrawn
    **before the async close/bye runs**, and every snapshot is marked before any is drained or torn
    down (observe ordering via a parked outbound sink recording what it sees).
  - `deregister` removes precisely by SessionID and does not wipe a reconnecting sibling; `disconnectAll`
    clears `byClient` **and** `sessions` (M-a/finding 8a).
  - **keepAwake linearization (finding 8b, M-a):** a `disconnectAll` `endAll` that races a `register`
    for a new id never releases the new id's assertion (barrier disconnect/register test, injected
    `KeepAwake` backend, assert the assertion balances); nil-key legacy sessions are untouched by
    `beginRevoke`.
- **`SessionCapability`**: `invalidate()` flips `isValid` under concurrent reads; `perform` runs the
  effect iff valid and is mutually exclusive with the drain (barrier test — an effect in `perform`
  and a concurrent `invalidate` never both "win"). **Bounded-wait (H-b):** a `perform` around one
  irreducible effect blocks the drain for at most that one effect; a large `.typeText` gated
  per-CGEvent lets `invalidate` win after one event (observe via `InputInjector.postEvent` count after
  invalidate; mirror `InputInjectorGateTests`). **Mark/drain split (Sol review C1):** `markInvalid()`
  returns — and `isValid` reads false — while an effect is still parked mid-flight; the drain alone
  blocks until it finishes; a second `perform` that queued behind the in-flight effect is refused
  after the mark (the ≤ one-effect residual bound — the test must PROVE the second caller was queued
  on `effectLock` when the mark landed, not merely rejected by the fast path: signal at the gate, then
  assert it stays blocked across the mark and returns only once the first effect is released).
  **Batch bound:** with two sessions under one key
  each parked inside `perform`, `beginRevoke` marks BOTH before draining either, and the sibling
  cannot start a new effect while the first is still parked
  (`HostControlRegistryTests.beginRevoke_marksEverySiblingInvalidWhileASessionIsParkedInsidePerform`);
  `evictLegacyAdmitted` likewise invalidates every capability before any transport teardown.
- **Shutdown Invalidate-First (Sol review I3):** `cancelServe` marks the session capability **before**
  the transport close (observe the flag from inside the close closure), does not block on a parked
  in-flight effect, and a cancel that fires before the capability is published still withdraws the
  later-published one.
- **R9 host-local gate at the effect boundary (Sol review I4a, re-review I4):** the test must land the
  mark AFTER the serve loop's branch check and BEFORE the effect — the interleaving a branch-level
  check cannot survive — and assert the privileged effect did **not** occur. Real units, not a
  factored helper: `CaptureEngine.setViewport` (through the `installConfigurationApplierForTesting`
  seam — no live `SCStream`, mirroring why `InputInjector.postEvent` is a seam) issues no
  `updateConfiguration` and mutates no config field after withdrawal; `CaptureEngine.requestKeyframe`
  sets no flag; `ClientFeedbackHolder.update` refuses the write and leaves the previous snapshot.
  Plus the drain coupling the old gate lacked: with a reconfiguration parked mid-issue, a concurrent
  `drainInFlightEffect()` cannot return. The `SCStream.startCapture` boundary is gated but **not**
  headlessly testable (no constructible `SCDisplay`).
- **FileReceiver post-withdrawal boundaries (Sol review I4b):** a zero-length FINAL chunk does not
  finalize the transfer (it stays in flight for `cancelAll`) while the same chunk under a valid
  capability does; a quota-crossing chunk does not close+delete the partial file.
- **Size caps (H-b):** an over-cap `.typeText` / inbound `.clipboardUpdate` / `.fileChunk` is skipped
  at the serve boundary (no injection / no pasteboard write / no file write); a within-cap one runs.
- **`InboundBuffer.finishDiscardingBuffered`** *(security-critical, finding 7)*: with buffered
  control/audio/video present, the next `next()` returns `nil`; a parked waiter resumes `nil`. **Barrier
  test:** a concurrent `enqueue` racing the discard never yields a message from a subsequent `next()`,
  and returns `.droppedFinished`. Contrast: `finish()` still drains.
- **`PortholeConnection.closeDiscardingInbound`**: drive `processIncoming` (`:252`) to queue frames,
  then `closeDiscardingInbound`; assert `inbound` ends without yielding them, the buffer is terminal
  **before** the transport cancel, and a receive callback delivering after finish yields
  `.droppedFinished` and **does not re-arm** `receiveNext`.
- **Outbound capability (finding 4, H-e):** a `pumpVideo`/router send with an invalidated capability
  drops (no send on the fake `LaneStreamSender`); the `OutboundLane` sink drops a taken-but-not-sent
  message after invalidate; `router.closeBoundLanes` closes bound secondary senders **and refuses a
  late `bind` after close**. Pin the defined residual in a comment/test name (in-flight bytes out of
  scope to recall).
- **Direct-send gating (H-e):** with the capability invalidated during the durable `await`, the
  post-await recheck terminalizes so **no** `ServerHello`, **no** initial lock-status, and **no**
  `didBuildScaffolding` fire; a pong for a message arriving after invalidate is dropped.
- **Clipboard MainActor recheck (finding 3, H-d):** `applyRemote` with an invalidated capability does
  **not** mutate the (fake) pasteboard even though the write is deferred to a MainActor task —
  including when the invalidation came from a **normal** teardown, not a revoke.
- **Admission TOCTOU + ordering (findings 1, 5; H-e)** (drive `serveSession` via `onAuthGateOutcome` /
  `didBuildScaffolding`): a revoke landing between gate-authorize and register self-closes at the
  fence/generation check; a revoke landing **during the durable `await`** self-closes at the post-await
  recheck — both with **no** `ServerHello`, **no** clipboard send, `didBuildScaffolding` never fires.
  Assert clipboard polling and the outbound producers start only *after* the post-await recheck.
- **`PairingStore.touch` no-resurrect (finding 6, H-a):** after `revoke(id: K)` removes K from the
  authorization item, a `touch(id: K)` does **not** re-add K to the authorization item; `isAuthorized(K)`
  is false. **Cross-process barrier (H-a):** two `PairingStore` instances over one fake record store;
  pause instance-B's `touch(K)` **after** its read, `revoke(K)` on instance-A, resume B's `touch`;
  assert K stays absent from the authorization item (lastSeen writes go only to the lastSeen item).
- **`PairingStore.list` join:** `list()` reflects the enrolled set with `lastSeen` joined from the
  separate item (default `enrolledAt` when absent); an orphan lastSeen entry for a revoked key is not
  surfaced.
- **Mutation freshness (§6d C2):** two `PairingStore` instances over ONE fake record store, both warm
  on {K, J}; A `revoke(K)`, then B (warm+stale) `revoke(J)` — a third instance must see K **absent**
  (`staleWarmCacheCannotResurrectAKeyRevokedByAnotherInstance`); same via B's unrelated `enroll(X)`
  (`staleWarmCacheCannotResurrectARevokedKeyOnEnroll`); and with a warm cache + a throwing read,
  `enroll`/`revoke` **throw** while `isAuthorized` still serves the cache — the asymmetry pinned
  (`mutationPropagatesAReadFailureEvenWithAWarmCache`).
- **Durable revocation intent (§6d I5), the restart case:** enroll K, force the authorization write to
  throw so `revoke(K)` fails, then build a **FRESH** `PairingStore` over the same items (= the next
  process): `isAuthorized(K)`/`authorizedClient(K)` are false, `pendingRevocations() == [K]`, and
  `list()` still contains K so the UI can finish the op
  (`recordedRevocationIntentSurvivesARestartAndFailsClosed`, which also pins that this failure reports
  `RevokeIncomplete.fencedDurably`). Then: Retry with **no lease** completes it
  and clears the intent (`retryAfterARestartCompletesTheRevokeAndClearsTheIntent`);
  `cancelRevocationIntent` re-admits durably (`cancelRevocationIntentReAdmitsTheStillEnrolledDevice`)
  and **throws rather than reporting a false re-admission** when the intent item can't be written
  (`cancelRevocationIntentThrowsRatherThanReportingAFalseReAdmission`); a successful revoke leaves no
  intent (`successfulRevokeLeavesNoIntentBehind`); an attended re-enroll clears a stale one
  (`attendedReEnrollClearsAStaleRevocationIntent`); an intent-item write failure still attempts — and
  reports — the removal (`intentWriteFailureStillAttemptsTheDurableRemoval`); one key's intent never
  fences another and a second wedged revoke doesn't drop the first's intent
  (`aPendingIntentForOneKeyNeverFencesAnother`); a cold unreadable or corrupt intent item authorizes
  nobody (`unreadableIntentItemFailsClosedOnAColdRead`, `corruptIntentBlobFailsClosed`) while a WARM
  set survives a mid-session lock (`warmIntentCacheKeepsAuthorizingWhenTheIntentItemLocksMidSession`).

  **Test-honesty note (Sol re-review; five of the above previously passed for the wrong reason).**
  "Leaves no intent behind" must be asserted against the DURABLE intent blob (`durableIntents(_:)`
  decodes the injected item directly), never inferred from a re-enroll — `enroll` clears the intent
  itself, so a re-enroll-based assertion holds whether or not `revoke` ever cleared anything. Likewise
  `pendingRevocations()` cannot prove clear-on-completion (it intersects with the enrolled set, so an
  orphan for the just-removed key is filtered away), the restart tests must check the restarted store
  **before** the Retry (that is the only assertion the durable-intent mechanism is load-bearing for),
  and the "a second wedged revoke doesn't drop the first's intent" counterexample needs a **SECOND
  actor warmed BEFORE the first actor's intent write** — with one actor its intent cache already holds
  the first id, so a `mutableIntents()` that wrongly served the cache still passed.
- **Non-durable revoke, reported not swallowed (§6d item 5, Sol re-review):** fail the intent write AND
  the authorization write → `revoke` throws `RevokeIncomplete.notDurable` (distinct from
  `.fencedDurably`), and a fresh instance genuinely re-admits K — the honest outcome, asserted rather
  than papered over (`revokeSurfacesANonDurableFenceWhenTheIntentWriteAlsoFails`). Then let the intent
  write recover while the authorization write keeps failing: the next `revoke` (= the UI's Retry)
  promotes the same op to `.fencedDurably` and a fresh instance denies K
  (`retryRecordsTheIntentTheFirstAttemptCouldNotWrite`).
- **Unknown ≠ proven absent (§6d item 5, Sol pass 3 N1):** land a durable intent (removal fails →
  `.fencedDurably`), then fail the intent **read** on the Retry → `revoke` throws `.durabilityUnknown`
  (`isDurablyFenced == false` AND `isProvenNotDurable == false`), the durable `{K}` blob is untouched,
  and a fresh instance still denies K — the case the two-state report announced as "regains access on
  restart" (`aFailedIntentReadReportsUnknownDurabilityNotProvenAbsence`).
- **No false enrollment success (§6d item 8, Sol re-review):** with a pending intent that cannot be
  written, `enroll` **throws** instead of persisting the record and reporting approval for a key the
  gate still denies (`enrollThrowsRatherThanReportingSuccessForAKeyThatStaysFenced`); same when the
  intent item is undecodable so the clear cannot even be attempted
  (`enrollThrowsWhenAPendingIntentCannotEvenBeRead`). And the UI view never launders an unreadable
  intent item into a reassuring empty set (`pendingRevocationsReportsUnreadableRatherThanACleanEmptySet`).
- **…and that refusal binds THIS process (§6d item 8a, Sol pass 3 N2):** the interleaving the two tests
  above miss is a **warm-empty** `intentCache` (not a cache already holding the id, not a cold corrupt
  item) plus an intent item that goes unreadable while the authorization item stays writable — the
  enroll persists, throws, and the still-warm `[]` used to re-authorize the key on its next handshake.
  Assert the thrown enroll leaves the key unauthorizable in the same instance (before and after the
  read recovers), that an unrelated device stays authorized, and that the attended Cancel is what lifts
  it (`aFailedEnrollLeavesTheKeyUnauthorizableEvenWithAWarmEmptyIntentCache`).
- **Window lease (finding 9a/9b, CONFIRMED):** a `.sasCode` stamped with a prior `WindowLease` is
  ignored while a newer window is open; `claimCodeDisplay` rejects a claim whose lease is not the
  current open window's.
- **Decision tokens (finding 9c, CONFIRMED):** a second `approveEnrollment` for an attempt already in
  flight is rejected (no second LAContext); a stale task's `defer` clears only its own token.
- **CLI control minting (M-b):** `HostRunner.run` with `control: nil` mints a process-local
  `HostControl` and `serveSession` registers/evicts against it (drive via the loopback integration seam
  that already exercises `serveSession`).

### Device-gated `[?]` (hardware, human-attended)

- End-to-end: enroll → stream → revoke from menu bar (LAContext + confirm) → the live session dies
  immediately (screen, input, clipboard, file all stop producing); queued input does **not** execute
  post-revoke; a large paste/typeText mid-revoke is cut within one event/chunk.
- Revoke → re-enroll the same device → the new session survives (generation).
- Two concurrent sessions from one device → revoke kills both.
- Durable-failure path: force a keychain error on `pairings.revoke` → the row shows incomplete; K
  cannot reconnect (fence retained); Retry completes it; authenticated Cancel re-admits.
- Last-device revoke → host is locked out until an attended re-pair; UI copy correct (decision 2).
- Cross-process: an app-side revoke does **not** kill a separately-running CLI host's *current* live
  session, and never resurrects K durably via `touch` (documented semantic, not a regression).

---

## 9. Out of scope

- **Cross-process live invalidation** (shared IPC authority / cache-invalidation signal) — §6c
  documents the semantic; synchronous cross-process kill is not built.
- **A genuine cross-process CAS for the pairings items — BOTH the authorization blob AND the
  revocation-intent blob** — tracked as bead **`portview-auf`**. The H-a fix removes `touch` from the
  authorization-write path entirely (separate lastSeen storage) and the C2 fix (§6d) makes every
  remaining mutation re-read the durable item immediately before its read-modify-write, so what is left
  is genuinely last-writer-wins **over a fresh read**: two `enroll`/`revoke` RMWs that interleave
  *inside* that narrow window can still lose one update, and a lost `revoke` update means a revoked key
  stays enrolled (the UI reported success).

  **The intent item does not rescue this, and is subject to the same defect (Sol re-review).** The
  earlier text claimed a lost authorization update was still covered because the intent denies K. That
  reasoning is INVALID: the intent set is also a whole-blob RMW with no CAS, so it loses concurrent
  writes in exactly the same shape — P1 reads `{}`, P2 reads `{}`, P1 writes `{K}`, P2 writes `{J}`,
  and **K's intent is gone**. Both writes reported success and K is neither removed nor fenced. So the
  honest statement is: a lost update on the authorization blob is *usually* covered by the intent,
  except when the intent write is the one that loses — and nothing in this wave orders the two. Still
  accepted for this wave because these operations are attended, rare, and serialized in practice (one
  human, one app, at one Mac), but `portview-auf` must cover **both items**, not just the authorization
  one. What is NOT built: a compare-and-swap (generation/etag on the blob, or a lock item) that would
  make either RMW atomic across processes.
- **Releasing OS input state stranded by a revoke** — bead **`portview-5a5`**. Input is gated
  per-CGEvent, so a revoke landing BETWEEN a key-down and its key-up (or a mouse-down and its up) lets
  the down through and refuses the up, leaving a stuck/repeating key or a still-pressed drag on the
  host after the device is gone. §4's "one irreducible effect" bound is per-event and does **not**
  cover paired-edge state — this is a named residual of the revoke design, not an oversight in it. The
  remediation (track pressed edges per injector; emit the matching ups as a teardown pass that is
  deliberately NOT gated by the now-invalid capability, because the release IS the remediation) is
  owned by `portview-5a5`.
- **A typed "revoked" wire signal** to the client — revoke is a silent synchronous close by design
  (invariant 5, no-oracle stance). The client infers it from the drop + gate failure.
- **Key rotation ceremony** and **mTLS upgrade** (future beads).
- **`ProtocolVersion` sequencing** — untouched (decisions.md 2026-07-21 item 4).
- **Durable per-key generation** — deliberately in-memory, single-process; it does not survive host
  restart (nor needs to: a restart has no live sessions to protect).

---

## 10. New risks the v3 machinery introduces (for the next review pass)

- **R1 — nested locks HostControl.lock → keepAwake.lock → IOKit (finding 8 / M-a).** *CONFIRMED safe
  today.* Moving `sessionBegan`/`sessionEnded`/`endAll` inside the HostControl lock nests locks and
  holds HostControl's lock across an IOKit assertion call (a quick syscall) and the ticker's async
  schedule. Safe only while the nesting stays one-directional — **KeepAwake never calls back into
  HostControl** (true today; document this as a contract). No reentrancy, bounded hold.
- **R2 — `capability.perform` holds its lock across the effect, now BOUNDED (H-b).** Because `perform`
  wraps only an irreducible effect (one CGEvent / one pasteboard write / one file-chunk write) and
  inbound messages are size-capped, `invalidate()` waits at most one such effect and never under
  `HostControl.lock`. Verify: every closure passed to `perform` is strictly synchronous, irreducible,
  and non-reentrant — **no `await`, no compound multi-OS-effect body, no nested capability call** — or
  it would re-open the starvation H-b closes.
- **R3 — defined outbound residual, now extended to direct sends (H-e).** Confirm no producer path —
  including the direct `ServerHello`/lock-status/pong sends — reaches `connection.send` without an
  `isValid` pre-check, and that `closeDiscardingInbound` + `closeBoundLanes` reclaim the primary and
  every bound secondary stream promptly, so the residual is truly bounded to already-in-transport bytes.
- **R4 — `touch` now writes a SEPARATE lastSeen item per authenticated handshake (H-a).** A keychain
  write to the lastSeen item per connect (acceptable frequency), and no longer any read/write of the
  authorization item on the `touch` path. Verify a locked-keychain `touch` no-ops (keeps the old
  lastSeen) rather than throwing into the handshake, and that the authorization item is never opened by
  `touch`.
- **R5 — durable-revoke failure after a successful live kill, now FAIL-CLOSED (H-c).** If
  `pairings.revoke` throws, the live sessions are already dead and the generation stays bumped, and the
  fence is **retained** (K unauthorizable) instead of lifted — so K cannot re-admit *in this process*.
  Beyond it, see invariant 6b: durable iff the revocation intent is recorded (`.fencedDurably`); when
  it provably is not (`.notDurable`) a restart re-admits K, when the item could not be read
  (`.durabilityUnknown`) neither outcome is known — and the UI is required to say which of the three it
  has, categorically only in the proven case. Verify: the UI
  surfaces the incomplete state, Retry re-attempts under the same lease and lifts on success, and the
  LAContext-gated Cancel is the only path that lifts the fence without a durable revoke (deliberate,
  authenticated re-admission of a still-enrolled key).
- **R6 — Order-A straddle semantics (CONFIRMED).** A handshake straddling a revoke→re-enroll is forced
  to reconnect (killed at register on a stale generation) rather than surviving into the new
  enrollment. Confirmed the correct conservative direction; a surviving straddle would require capturing
  the generation *after* the durable lookup — the opposite trade.
- **R7 — NEW: separate lastSeen storage introduces its own cross-process anomalies (H-a fix).** Two
  processes racing `touch` on the lastSeen item lose one update (last-writer-wins on the whole
  lastSeen blob) — **cosmetic**, `lastSeen` never gates authorization. A `touch(K)` racing a `revoke(K)`
  can leave an **orphan** `lastSeen[K]` for a no-longer-authorized key — harmless because `list()`
  surfaces only keys present in the *authorization* item.

  **Correction (Sol re-review): nothing prunes, so the item CAN grow unboundedly.** The earlier
  sentence claimed "`list()`/a sweep prunes lastSeen keys absent from the auth set so the item cannot
  grow unboundedly" — `list()` does no such thing. It iterates the enrolled set and joins values out of
  the lastSeen map (`PairingStore.list()`), filtering the *rendered inventory* only; it never writes a
  pruned map back, and there is no sweep anywhere. So every orphan produced by a `touch(K)` racing a
  `revoke(K)`, or by a failed best-effort `deleteLastSeen`, is **permanent**. It stays cosmetic — an
  orphan can never re-authorize, because authorization reads a different item entirely — but the growth
  bound does not exist today. The deferred work is bead **`portview-1z1`** (prune in `list()` or a
  periodic sweep, keeping `list()` cheap and never letting a lastSeen failure touch authorization); the
  same gap applies to orphan revocation *intents* (§6d Residual 1). Verify what is actually true: the
  lastSeen item is read strictly best-effort and never on the authorization path, and no orphan is ever
  surfaced (`PairingStoreTests.listDoesNotSurfaceOrphanLastSeenForARevokedKey`).
- **R8 — out-of-lock mark window, now split mark/drain (H-b × H-d interaction; REVISED by Sol review
  C1).** Moving withdrawal out of `HostControl.lock` (R3-of-H-b) opens a brief window between the
  under-lock snapshot/unlink and the out-of-lock withdrawal, during which one already-in-flight
  irreducible `perform` — or one queued deferred MainActor pasteboard write whose `perform` has not
  yet run — can still execute on a snapshotted-but-not-yet-withdrawn capability.

  **The bound did not originally hold.** With withdrawal as ONE blocking operation sharing the
  effect lock, a batch teardown's first `invalidate()` blocked for the entire duration of that
  session's in-flight effect (e.g. a stalled `FileHandle.write`), and every *later* session under
  the same key stayed valid — with its inbound still open, since transport teardown is a later pass
  — for the whole stall. A revoked device with two concurrent sessions kept full
  keyboard/pointer/clipboard/file control through the sibling. `evictLegacyAdmitted` was worse: it
  still interleaved each session's invalidation with its own transport teardown.

  **The fix** is `SessionCapability`'s two-lock split — `markInvalid()` (non-blocking, flag lock
  only) and `drainInFlightEffect()` (blocking, effect lock) — with every batch teardown running
  **mark-all → drain-all → tear down transports**. `perform` re-checks the flag *under* the effect
  lock, so a second effect that queued behind an in-flight one is refused rather than run. Restored
  bound: **≤ one already-in-flight irreducible effect per capability**, and one session's stall can
  no longer extend any sibling's window.

  **Where a global revoke actually linearizes (Sol re-review C1).** NOT at `beginRevoke` entry, and
  NOT at the under-lock fence/generation write — those stop *new admission* for K, not the sessions
  already holding a live capability. Authority for the set is withdrawn only at **completion of the
  out-of-lock mark-all pass**: `markInvalid()` is per capability, so a capability later in that pass
  is still valid — and may legitimately start and complete a whole irreducible effect — until its own
  mark lands. The pass is O(sessions) with no blocking call in it, so that skew is short and bounded,
  but it is real and must not be described as instantaneous. The two bounds that matter are stated
  per capability, not per operation: no NEW effect after *that capability's* `markInvalid()` returns,
  and ≤ one already-in-flight effect drained out by pass 1. Verify: no path drains before every snapshot is marked; no
  path withdraws *before* snapshotting (which would defeat Invalidate-First on the batch paths); the
  serve-defer path (synchronous mark+drain, not out-of-lock) has **zero** such window; and no
  `perform` closure ever calls back into its own capability (a re-entrant `perform`/drain deadlocks
  on the effect lock). Regression:
  `HostControlRegistryTests.beginRevoke_marksEverySiblingInvalidWhileASessionIsParkedInsidePerform`.
- **R9 — parked-waiter single-message residual (Task-2 finding; backstop EXTENDED by Sol review
  I4a/I4b).** §4.4: a lone inbound message whose `enqueue` wins the lock the instant before the
  discard, while a consumer is parked in `next()`, is handed to that continuation and can reach the
  serve loop after withdrawal. Bounded to **one** message; the backstop is layer-1, the capability
  check at the effect boundary. That backstop was incomplete in two places, both now closed:
  **(a)** the serve loop's host-local session-control branches (`.startSession`/`.switchDisplay` →
  build a `CaptureEngine` and start the video task, `.viewport` → re-crop the live capture,
  `.clientFeedback` → steer the encoder, `.requestKeyframe`) had no capability check at all — only
  *outbound* was gated — so a revoked peer could reconfigure or START screen capture. The first fix
  added a check at the BRANCH (`applySessionControl`); Sol's re-review showed that was still broken
  (check-then-use across a suspension, and no `effectLock` coupling, so a drain returned at once), so
  the gates now sit at the irreducible boundary inside `CaptureEngine`/`ViewportState`/
  `ClientFeedbackHolder` and `applySessionControl` is gone (§4.1b). **(b)** `FileReceiver` gated only
  `createFile` and the non-empty `handle.write`, leaving a zero-length final chunk able to finalize a
  transfer and a quota-crossing chunk able to close **and delete** the partial file; both boundaries
  are now gated (§4.1). **(c)** `setViewport`'s tolerance-qualified no-op branch still wrote session
  state after a bare, lock-free check (invariant 2's old residual (ii) first half); it now writes
  nothing at all, so every branch really does reach an unsuspended gate or perform no write (Sol pass
  3 N3). Verify: every branch of the serve loop that mutates host state or touches the filesystem
  reaches a capability check that is not separated from its effect by a suspension.
  Regressions: `CaptureEngineTests.aRevokeLandingAfterTheServeLoopCheckStopsTheLiveRecropAtTheOSBoundary`
  / `…StopsTheKeyframeRequest` / `drainWaitsForAnInFlightLiveRecropInsteadOfReturningAtOnce` /
  `aKeyframeRequestQueuedOnTheEffectLockIsRefusedByTheUnderLockRecheck` /
  `aToleranceQualifiedNoOpRecropWritesNoSessionStateAtAll`,
  `HostRunnerTests.clientFeedbackHolderRefusesTheEncoderWriteAfterWithdrawal`,
  `FileReceiverTests.emptyFinalChunk*` /
  `quotaCrossingChunkUnderInvalidatedCapabilityDoesNotDeleteThePartialFile`.

  **Test-barrier note (Sol pass 3).** Four of those regressions previously landed their mark
  *immediately before invoking* the gated operation, which only exercises the fast-path reject — they
  stayed green with the authoritative mechanism removed. The mark now lands at the real
  post-fast-path / pre-`effectLock` point via `SessionCapability.setWillAcquireEffectLockForTesting`,
  an internal, production-`nil` seam (same precedent as `InputInjector.postEvent` and
  `CaptureEngine.installConfigurationApplierForTesting`) that takes no arguments, returns nothing and
  therefore delegates **no** production authority — both `guard`s still read only `valid`.
  **Not closed headlessly:** the `SCStream.startCapture` boundary is gated but has no test —
  `SCDisplay`/`SCContentFilter` cannot be constructed without a real display and a test must never
  touch the live capture surface.
- **R11 — NEW: the revocation-intent item is now on the authorization path (§6d, I5).** Unlike lastSeen,
  this third item **gates** authorization, so it adds a keychain dependency to every cold authorization
  decision: an unreadable/undecodable intent item denies EVERYONE (deliberate, symmetric with an
  unreadable authorization item — but it is a new way to fail closed). Mitigations in place: the set is
  warm-cached after the first successful read (a mid-session lock does not brick a live host), it is
  read-only on the authorization path (writes happen only in `revoke`/`enroll`/`cancelRevocationIntent`,
  all attended and rare), and an intent write can never add or drop an enrolled key (separate item).

  **Three honest consequences of putting it on the authorization path (Sol re-review):**
  - **An orphan intent after a SUCCESSFUL revoke is real, and is not swept.** The final clear is
    best-effort, so "a completed revoke leaves no intent behind" is a *goal*, not a guarantee. The
    orphan authorizes nobody (its key is no longer enrolled) and `pendingRevocations()` filters it out
    by intersecting with the enrolled set, but it persists until the next `enroll`/`revoke` of that id
    — and it accumulates, exactly like R7's orphan lastSeen entries (`portview-1z1` covers the sweep).
  - **A corrupt/unreadable intent item is a LOCKOUT with no in-app exit today.** It denies everyone,
    `cancelRevocationIntent` cannot help (it re-reads the same broken item and throws), and `enroll`
    now correctly refuses rather than reporting a false success — which is right, and also means the
    only recovery is manual keychain deletion. The attended, LAContext-gated store-wide repair that
    overwrites the item without reading it is bead **`portview-oj5`**; the UI's job until then is to
    say the store is unreadable (`PendingRevocations.unreadable` → the popover banner) instead of
    rendering a clean list.
  - **The intent item is a whole-blob RMW with no CAS**, so two concurrent intent writes lose one —
    including one that carries a pending fence (§9, `portview-auf` now scoped to both items).

  Verify: no authorization path writes the intent item; a warm set survives a locked keychain; an
  unreadable item is reported as `.unreadable` and never as an empty pending set; an enrollment over an
  undischargeable intent THROWS rather than reporting approval; an attended re-enrollment clears a
  pending intent so a wedged revoke cannot permanently lock out a re-paired device. Regressions:
  `PairingStoreTests.recordedRevocationIntentSurvivesARestartAndFailsClosed`,
  `…/attendedReEnrollClearsAStaleRevocationIntent`,
  `…/warmIntentCacheKeepsAuthorizingWhenTheIntentItemLocksMidSession`,
  `…/enrollThrowsRatherThanReportingSuccessForAKeyThatStaysFenced`,
  `…/enrollThrowsWhenAPendingIntentCannotEvenBeRead`,
  `…/pendingRevocationsReportsUnreadableRatherThanACleanEmptySet`,
  `…/aFailedEnrollLeavesTheKeyUnauthorizableEvenWithAWarmEmptyIntentCache`.

  **Fourth consequence (Sol pass 3 N2).** Putting the item on the authorization path also means an
  authorization decision can be served from a **warm** intent set that a mutation has just proven
  stale. The concrete case is §6d item 8a: a warm-empty `intentCache` plus an intent item that goes
  unreadable let the gate admit a key whose `enroll` had already reported failure. The mitigation is
  the per-id `unverifiedIntentFence` (subtracted by `authorizedMap()`, surfaced by
  `pendingRevocations()`, lifted only by a successful discharge), chosen over poisoning the warm cache
  precisely to keep the item-7 mid-session-lock resilience intact for every *other* device. Verify: a
  thrown `enroll` leaves its key unauthorizable in the SAME process even when the intent cache is warm
  and empty, while an unrelated enrolled device stays authorized.
- **R10 — NEW: shutdown-path withdrawal is a MARK, not a drain (Sol review I3).** `serve`'s
  cancellation handler now marks the session capability (through `SessionCapabilityBox`) before
  `connection.close()`, so Invalidate-First holds on host shutdown. It deliberately does **not**
  drain: a cancellation handler runs synchronously on the cancelling thread, and draining there would
  let one stalled irreducible effect wedge "Stop Hosting". The residual is therefore the usual ≤ one
  in-flight effect, and `serveSession`'s defer still performs the full mark+drain as the loop
  unwinds. Verify: the box is published before any producer is built, a cancel that fires *before*
  publication still withdraws the later-published capability, and nothing in the handler can block.

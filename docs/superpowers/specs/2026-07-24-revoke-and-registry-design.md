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
  serve-defer, `disconnectAll`, `evictLegacyAdmitted`, a failed post-register recheck, a
  register-reject self-close, and revoke — `capability.invalidate()` runs **before** any registry
  removal or async teardown. v2 only invalidated on the revoke path, so a deferred effect (a queued
  MainActor pasteboard write) could outlive a *normal* disconnect on a still-valid capability.
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
  **snapshots** target capabilities under `HostControl.lock` and **invalidates them OUT of the lock**
  (§1a, §4). Net: `invalidate()` waits at most one irreducible effect, and never while
  `HostControl.lock` is held (§10 R2 now bounded).
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
   - **Out of the lock (H-b, H-d ordering):** for each snapshot, in order:
     `capability.invalidate()` **first** (bounded wait ≤ one irreducible effect — §4), then
     `session.outbound.finish()` (drop queued clipboard/cursor/file/broadcast sends), then
     `session.connection.closeDiscardingInbound()` (§4). **No graceful `bye`** (unlike
     `disconnectAll`, `HostControl.swift:120`).
   - Return `RevokeReceipt(lease:, evictedCount:)`.
4. **Durable removal (second).** `try await pairings.revoke(id: K)` on the **shared** `PairingStore`
   instance (§2). `migrationComplete` is never cleared (`PairingStore.swift:147`), so revoking the
   last device keeps the host `.required` (decision 2).
5. **Finalize — CONDITIONAL on durable success (H-c, fail CLOSED).**
   - **Durable revoke succeeded** → `control.endRevoke(lease: receipt.lease)`. `endRevoke` lifts the
     fence **iff** the lease it is handed is the current lease for K (matching-lease-required — a
     stale lease never lifts a newer op's fence). The generation stays bumped forever.
   - **Durable revoke threw** (keychain error) → **do NOT call `endRevoke`.** The fence stays; K is
     unauthorizable (the still-durably-enrolled record cannot mint a session while K ∈ `revoking`).
     The op is surfaced as **incomplete** with two authenticated actions:
     - **Retry** — re-run step 4 under the *same* lease; on success, `endRevoke(lease:)`.
     - **Cancel** — an `LAContext`-gated `control.cancelRevoke(lease:)` that lifts the fence WITHOUT a
       durable revoke, deliberately **re-admitting** the still-enrolled K (the escape hatch for a
       permanently-wedged keychain; the owner accepts the risk). Cancel requires the matching lease.
   The live kill in step 3 already happened and the generation bump is permanent regardless, so a
   failed durable step can never resurrect a killed session — it only leaves K live-*re-admittable*,
   which the retained fence blocks (new-risk R5, now fail-closed).
6. **UI refresh.** Reload `pairings.list()` → the revoked row disappears (on durable success). **If
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
  lock, **no invalidate/close under the lock**), then **out of the lock** invalidate-first + finish +
  `closeDiscardingInbound` each snapshot. Returns the opaque `RevokeReceipt`. Teardown is internal
  (M-b). `HostAppModel.revoke` orchestrates begin → `await pairings.revoke` → end/retain (§1a).
- **`HostControl.endRevoke(lease:) / cancelRevoke(lease:)`** (NEW). `endRevoke` removes K from
  `revoking` **iff** `revoking[K] == lease` (matching-lease-required); the generation stays bumped.
  `cancelRevoke` is the same fence-lift but is the authenticated escape hatch invoked only from the
  `LAContext`-gated Cancel action on a durable failure (§1a step 5). Both no-op on a stale lease.
- **`HostControl.evictLegacyAdmitted`** (`HostControl.swift:106`). Upgrade to the §4 primitive AND
  Invalidate-First: under the lock, snapshot the legacy sessions + `keepAwake.sessionEnded` + remove
  from `sessions`; **out of the lock**, `capability.invalidate()` **first**, then `outbound.finish()`
  + `closeDiscardingInbound()` — replacing the draining `connection.close()` at `:113`. Legacy
  sessions carry no `keyID`, so `byClient` needs no update. Closes the han.3 residual and the H-d
  "legacy eviction leaves the capability valid" hole.
- **`HostControl.disconnectAll`** (`HostControl.swift:120`). Under the lock: snapshot sessions,
  `sessions.removeAll()`, **clear `byClient`** (M-a/finding 8a — it currently clears only `sessions`,
  `:123`), and `keepAwake.endAll()` **inside the lock** (M-a — it currently runs after `unlock`,
  `:124–125`, racing a new `sessionBegan`). Out of the lock: `capability.invalidate()` **first** on
  each snapshot (H-d — stops a deferred effect outliving the disconnect), THEN the graceful-`bye`
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
  is the irreducible effect; the serve loop wraps `capability.perform { fileReceiver.chunk(chunk) }`
  around one chunk, and caps `chunk.data.count` at the serve boundary (H-b). Per-file/per-session
  caps (`:56`) unchanged.
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
  (the mint-on-nil is the CLI path).

### New

- **`ClientKeyID`** — a thin alias/newtype over the existing `SHA256(pubkey)` hex string
  (`PairingStore.deviceID`, `PairingStore.swift:90`). No new derivation.
- **`AdmissionTicket`** — an immutable value `(keyID: ClientKeyID?, generation: UInt64)`, captured at
  authorization, carried by-value through register + recheck (the whole point of finding 1).
- **`SessionCapability`** (§4) — a lock-guarded per-session "may this session still act" flag, checked
  synchronously at each **irreducible** effect boundary and flippable synchronously by teardown/revoke.
  Pattern to mirror: `InputInjector`'s lock-guarded authority flag (`InputInjector.swift:16–29`) — but
  **per-session**, not the process-wide `paused`. Exposes `isValid` (read), `invalidate()`, and
  `perform(_ effect: () -> Void) -> Bool` (under the lock: if valid, run `effect`, return whether it
  ran). `perform` is for **strictly synchronous, irreducible** effects only — no `await`, no reentrant
  capability call, no compound multi-OS-effect closure (§10 R2).
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
authority, `capability.invalidate()` runs **before** any registry removal and before any async
teardown (bye / close / finish). The enumerated paths:

| Terminal path | Where invalidate lands |
|---|---|
| Normal serve-loop teardown | **first** statement of the `serveSession` defer (before `clipboard.stop`, `deregister`, cancels) |
| Register rejected (fence/gen) | self-close guard, step 6, before return |
| Post-await recheck fails (H-e) | recheck guard, step 6, before `deregister` |
| `beginRevoke` | out-of-lock, per snapshot, before `finish`/`closeDiscardingInbound` |
| `evictLegacyAdmitted` | out-of-lock, per snapshot, before `finish`/`closeDiscardingInbound` |
| `disconnectAll` | out-of-lock, per snapshot, before the graceful-`bye` Task |

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
   - file: `capability.perform { fileReceiver.chunk(chunk) }` around **one** chunk's single
     `handle.write` (`FileReceiver.swift:60`);
   - clipboard: inside `applyRemote`'s MainActor task, `capability.perform { pasteboard.clearContents();
     pasteboard.setString(text, .string); … }` around the **one** pasteboard mutation.
   `perform` holds the capability lock across the (bounded) effect; `invalidate()` takes the same lock,
   so each effect runs fully (then invalidate) or is skipped (invalidate first). Because the boundary
   is irreducible, `invalidate()` waits **at most one** such effect, whatever the message size.

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
   - **Out-of-lock invalidation window (NEW, R8):** because invalidation moves out of the lock (H-b),
     there is a brief interval between the under-lock snapshot/unlink and the out-of-lock
     `invalidate()` during which one already-in-flight irreducible `perform` (or one queued deferred
     MainActor pasteboard write) can still win its lock and execute. This is **one irreducible effect**,
     the same bounded class as the transport residual — not an unbounded stream. The security line
     holds because (a) the fence already blocks *new* admission for K, (b) the buffer is discarded so
     no *further* inbound is dispatched, and (c) size caps bound that one effect.
   The honest guarantee: **no NEW effect after `invalidate()` completes; a bounded one-irreducible-
   effect residual during the invalidation window, plus bytes already handed to the transport.**

**No graceful `bye` on revoke (unchanged).** `closeDiscardingInbound()` cancels the transport with no
farewell frame. `disconnectAll` (`HostControl.swift:120`) sends `bye` first *by design* (trusted
client); revoke must **not** — a de-trusted peer loses access at once, and a `bye` both delays the cut
and (client-side) suppresses the reconnect we no longer owe it. Matches han.3's no-oracle stance
(decisions.md 2026-07-23 item 4).

**Ordering within revoke:** (under lock) bump + fence + snapshot + unlink + keepAwake-end → (out of
lock, per snapshot) invalidate **first** → `outbound.finish()` → `closeDiscardingInbound()`. Never
close-then-invalidate: the transport close alone drains, so invalidation must land first.

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

---

## 7. Security invariants (must hold)

1. **Invalidate-Capability-First (H-d).** On **every** terminal path — normal serve-defer, register
   reject, failed post-await recheck, `beginRevoke`, `evictLegacyAdmitted`, `disconnectAll` —
   `capability.invalidate()` runs **before** any registry removal and before any async teardown
   (bye/close/finish). No deferred or in-flight effect outlives a session's authority on any exit.
2. **Effect-boundary invalidation at the IRREDUCIBLE unit, synchronous (finding 3, H-b).** Every
   privileged inbound effect is size-capped and runs through `capability.perform` around one
   irreducible OS effect (one CGEvent post, one pasteboard write, one file-chunk write) — never a
   compound message — so `invalidate()` waits at most one such effect. Buffered inbound is
   **discarded, never drained**; a finished buffer drops and never re-arms the receive loop.
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
7. **Generation captured at authorization, monotonic per key (finding 1, CONFIRMED).** The ticket's
   generation is fixed at the authorization instant; `admittedGen < currentGen ⇒ dead`. An
   already-admitted session, once revoked, can never be resurrected by a later re-enrollment.
8. **`byClient` is a set.** Registration never overwrites a concurrent/reconnecting session under one
   key; one revoke finds **all** of the key's live sessions.
9. **`touch` can never rewrite the authorization set (H-a).** `lastSeen` lives in separate storage (or
   is non-persisting); the authorization item is mutated only by `enroll`/`revoke`. A lastSeen bump
   cannot re-add a key absent from the authorization set — by construction, not by read ordering.
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
    is never resurrected by a stale `touch`, and is honored on the other process's next cold read.

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
  - **Invalidate-First (H-d):** on a normal `deregister`-driven teardown, on `evictLegacyAdmitted`, and
    on `disconnectAll`, the session's `capability` is `invalidate()`d **before** the registry entry is
    removed / the async close runs (observe ordering via a fake capability recording the call order).
  - `deregister` removes precisely by SessionID and does not wipe a reconnecting sibling; `disconnectAll`
    clears `byClient` **and** `sessions` (M-a/finding 8a).
  - **keepAwake linearization (finding 8b, M-a):** a `disconnectAll` `endAll` that races a `register`
    for a new id never releases the new id's assertion (barrier disconnect/register test, injected
    `KeepAwake` backend, assert the assertion balances); nil-key legacy sessions are untouched by
    `beginRevoke`.
- **`SessionCapability`**: `invalidate()` flips `isValid` under concurrent reads; `perform` runs the
  effect iff valid and is mutually exclusive with `invalidate` (barrier test — an effect in `perform`
  and a concurrent `invalidate` never both "win"). **Bounded-wait (H-b):** a `perform` around one
  irreducible effect blocks `invalidate` for at most that one effect; a large `.typeText` gated
  per-CGEvent lets `invalidate` win after one event (observe via `InputInjector.postEvent` count after
  invalidate; mirror `InputInjectorGateTests`).
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
- **`PairingStore.list` join:** `list()` reflects the authorization set with `lastSeen` joined from the
  separate item (default `enrolledAt` when absent); an orphan lastSeen entry for a revoked key is not
  surfaced.
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
- **A genuine cross-process CAS for the pairings item** — the H-a fix removes `touch` from the
  authorization-write path entirely (separate lastSeen storage), so no CAS is needed for the
  authorization set; `enroll`/`revoke` remain last-writer-wins whole-blob writes (as today), acceptable
  because they are attended, rare, and serialized in practice.
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
  fence is **retained** (K unauthorizable) instead of lifted — so K cannot re-admit. Verify: the UI
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
  surfaces only keys present in the *authorization* item and can prune orphans. Verify: the lastSeen
  item is read strictly best-effort and never on the authorization path; `list()`/a sweep prunes
  lastSeen keys absent from the auth set so the item cannot grow unboundedly across enroll/revoke churn.
- **R8 — NEW: out-of-lock invalidation window (H-b × H-d interaction).** Moving `invalidate()` out of
  `HostControl.lock` (R3-of-H-b) opens a brief window between the under-lock snapshot/unlink and the
  out-of-lock `invalidate()`, during which one already-in-flight irreducible `perform` — or one queued
  deferred MainActor pasteboard write whose `perform` has not yet run — can still execute on a
  snapshotted-but-not-yet-invalidated capability. This is **one irreducible effect**, the same bounded
  residual class as the transport bytes (§4), NOT an unbounded stream: the fence already blocks new
  admission, the inbound buffer is discarded (no *further* dispatch), and size caps bound that one
  effect. Verify: no path invalidates *before* snapshotting (which would defeat Invalidate-First on
  the batch paths), the window is bounded to one effect per capability, and the serve-defer path (which
  invalidates first *synchronously*, not out-of-lock) has **zero** such window — the out-of-lock window
  exists only on the batch paths (`beginRevoke`/`disconnectAll`/`evictLegacyAdmitted`) where H-b
  requires it, and is the accepted price of not freezing the registry lock.

# Revoke-kills-live + generation registry (han.4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax. This plan is deliberately interface-and-test-precise and defers codebase-derived implementation to the design doc — READ the design section named in each task before coding.

**Goal:** Make `revoke` sever a LIVE session (input/screen/clipboard/file) immediately and race-safely against reconnects and revoke→re-enroll of the same key, and close the deferred gate-admit→register admission TOCTOU — the final mutual-auth bead.

**Architecture:** An admission-time immutable `(keyID, generation)` ticket (captured in `serveAuthGate`) is checked at register and after the durable await; `HostControl` owns an in-memory per-key monotonic generation + a `RevokeLease` fence + a `byClient` set index; revoke is a single fenced operation that bumps the generation, snapshots occupants **under** the lock, and invalidates their per-session `SessionCapability` + discard-closes their transport **out of** the lock; capability is checked at each **irreducible** effect boundary and invalidated **first** on every terminal path.

**Tech Stack:** Swift 6 / swift-testing, SwiftPM package + xcodegen app targets, CryptoKit, LocalAuthentication (app), Security/keychain.

**Design doc (binding, read per-task):** `docs/superpowers/specs/2026-07-24-revoke-and-registry-design.md` (v3). Sections referenced below as §N. Every "mirror X @ file:line" and "follow §2 `<Unit>`" points there.

## Global Constraints

- TDD strictly: each task's tests are written and seen failing before implementation.
- **Invalidate-Capability-First** (§4 layer 0, invariant 1): capability is `invalidate()`d BEFORE registry removal or any async teardown on EVERY terminal path (serve defer, `deregister`-driven, `evictLegacyAdmitted`, `disconnectAll`, failed post-register recheck, revoke).
- **No await / no reentrant capability call / no compound multi-OS-effect inside `capability.perform`** (§10 R2) — perform wraps ONE irreducible synchronous effect only.
- **beginRevoke never holds `HostControl.lock` while invalidating/closing** — under the lock: bump gen + fence + snapshot + unlink + keepAwake-end; out of the lock: invalidate-first + finish + close (§2 `beginRevoke`).
- Revoke sends NO graceful `bye` (invariant 2); `disconnectAll` still does (it's the trusted disconnect).
- Never log/emit raw `publicKey` bytes — fingerprint/deviceID/name/lastSeen only (invariant 8).
- Product decisions (baked, §1a/§10): revoke gated by LAContext `.deviceOwnerAuthentication` + confirmation (mandatory); last-device revoke = locked-out-until-in-person-re-pair (migrationComplete stays set); surface both in UI copy.
- Tests never touch live system surfaces (memory `test-live-side-effects`): CGEvent via `InputInjector.postEvent` seam, pasteboard/keychain/IOPM via injected fakes.
- Verify each task: `swift test` green; app-touching tasks also `make build-host` / `make test-ios`. New app files → `xcodegen generate`.
- One commit per task; do not push. Security path: if a design requirement can't be met as written, STOP and flag — don't improvise.

---

### Task 1: `SessionCapability` (per-session act-permission flag)

**Files:** Create `Sources/PortviewHostCore/SessionCapability.swift`; Test `Tests/PortviewHostTests/SessionCapabilityTests.swift`.

**Interfaces — Produces:**
- `final class SessionCapability: @unchecked Sendable { init(); var isValid: Bool { get }; func invalidate(); @discardableResult func perform(_ effect: () -> Void) -> Bool }` — lock-guarded (mirror `InputInjector`'s authority-flag lock, `InputInjector.swift:16-29`, but per-instance). `perform`: under the lock, if valid run `effect` and return true; else return false. `invalidate`: under the lock set invalid.

- [ ] **Step 1: Failing tests** (§8 `SessionCapability`): `invalidateFlipsIsValid`; `performRunsIffValid` (valid → effect ran + true; after invalidate → not run + false); `performAndInvalidateAreMutuallyExclusive` — a barrier test: an effect parked inside `perform` (via a latch the effect waits on) and a concurrent `invalidate` never both "win" (either the effect completed under the lock then invalidate, or invalidate first then perform returns false — assert exactly one ordering, never a torn interleave). No `await` inside any `perform` closure.
- [ ] **Step 2:** Run `swift test --filter SessionCapability` — expect compile-fail (type missing).
- [ ] **Step 3:** Implement per the Interfaces block (NSLock, ~20 lines).
- [ ] **Step 4:** `swift test --filter SessionCapability` green.
- [ ] **Step 5:** Commit `feat: SessionCapability — per-session act-permission at the effect boundary (han.4)`.

### Task 2: Discard-not-drain inbound primitive

**Files:** Modify `Sources/PortviewTransport/InboundBuffer.swift`, `Sources/PortviewTransport/PortholeConnection.swift`; Test `Tests/PortviewTransportTests/` (extend the existing InboundBuffer/PortholeConnection suites — find them; mirror `processIncoming` seam usage at `PortholeConnection.swift:252`).

**Interfaces — Produces:**
- `enum EnqueueOutcome { case accepted(pauseReceive: Bool); case droppedFinished }` — `InboundBuffer.enqueue` returns this instead of `Bool` (§2 `InboundBuffer`; finding 7). Under the lock: `guard !finished else { return .droppedFinished }`.
- `InboundBuffer.finishDiscardingBuffered()` — under the lock: clear `controlLane`/`controlHead`/`controlBytesBuffered`/`audioLane`/`videoLane`, set `finished = true`, take + resume any `waiter` with `nil`. Contrast `finish()` (`:153`) which drains.
- `PortviewConnection.closeDiscardingInbound()` — mirror `close()` (`:129`) but call `finishDiscardingBuffered()` BEFORE `connection.cancel()`. `ingest` (`:239`) maps `.droppedFinished` so `receiveNext` never re-arms a finished buffer.

**Consumes:** none.

- [ ] **Step 1: Failing tests** (§8 `finishDiscardingBuffered` + `closeDiscardingInbound`): buffered control/audio/video present → next `next()` returns `nil`, parked waiter resumes `nil`; **barrier**: a concurrent `enqueue` racing the discard never yields a later message and returns `.droppedFinished`; contrast `finish()` still drains; drive `processIncoming` to queue frames then `closeDiscardingInbound` → `inbound` ends without yielding them, buffer terminal BEFORE transport cancel, a post-finish receive callback yields `.droppedFinished` and does NOT re-arm `receiveNext`.
- [ ] **Step 2:** Run — expect fail.
- [ ] **Step 3:** Implement per §2 `InboundBuffer`/`PortholeConnection`. Update ALL `enqueue` call sites to the new verdict (grep first; the receive loop's re-arm decision reads `.accepted(pauseReceive:)`).
- [ ] **Step 4:** `swift test --filter "InboundBuffer|Porthole|Inbound"` green; full `swift test` green (enqueue signature change ripples).
- [ ] **Step 5:** Commit `feat: discard-not-drain inbound close + terminal enqueue verdict (han.4 finding 7)`.

### Task 3: `PairingStore` lastSeen split (no-resurrect)

**Files:** Modify `Sources/PortviewTransport/PairingStore.swift`; Test extend `Tests/PortviewTransportTests/PairingStoreTests.swift`.

**Interfaces — Produces:** `lastSeen` moves to a SEPARATE keychain item (its own `service`/`account`, a `[ClientKeyID: Date]` blob). The authorization item (`Persisted.clients` + `migrationComplete`) is mutated ONLY by `enroll`/`revoke`. `touch(id:)` reads-modifies-writes ONLY the lastSeen item — it can no longer re-add a key to the auth set. `enroll` seeds `lastSeen[K]`; `revoke` best-effort deletes `lastSeen[K]`. `list()` joins the lastSeen item (default → `enrolledAt` when absent) and prunes orphan lastSeen keys. A thrown lastSeen read/write no-ops (preserve the actor's keychain-lock resilience).

**Consumes:** none (the existing injectable record-store seam; add a second injected store for lastSeen, mirror the existing `PairingRecordStore`).

- [ ] **Step 1: Failing tests** (§8 `touch no-resurrect` + `list join`): after `revoke(id: K)`, a `touch(id: K)` does NOT re-add K to the auth item and `isAuthorized(K)` stays false; **cross-process barrier** — two `PairingStore` instances over independent auth stores but a shared lastSeen fake; pause instance-B `touch(K)` after its read, `revoke(K)` on A, resume B `touch` → K stays absent from the auth item; `list()` joins lastSeen (default `enrolledAt`), an orphan lastSeen for a revoked key is not surfaced.
- [ ] **Step 2:** Run — fail.
- [ ] **Step 3:** Implement per §2 `PairingStore` / §6c. Keep `EnrolledClient.lastSeen` in the returned `list()` value (joined), but stop persisting it in the auth blob.
- [ ] **Step 4:** `swift test --filter PairingStore` green; full `swift test` green.
- [ ] **Step 5:** Commit `feat: split lastSeen into its own keychain item — touch can't resurrect a revoked key (han.4 H-a)`.

### Task 4: `HostControl` registry + generation + revoke lease (the crux)

**Files:** Modify `Sources/PortviewHostCore/HostControl.swift`; create `Sources/PortviewHostCore/AdmissionTicket.swift` (holds `ClientKeyID` typealias, `AdmissionTicket`, `AdmissionResult`, `RevokeLease`, `RevokeReceipt`); Test extend `Tests/PortviewHostTests/` HostControl/eviction suites (mirror `HostControlEvictionTests` loopback + the injected `KeepAwake` backend pattern).

**Interfaces — Produces (all under the existing single `NSLock`):**
- `typealias ClientKeyID = String` (SHA256(pubkey) hex, = `PairingStore.deviceID`).
- `struct AdmissionTicket: Sendable { let keyID: ClientKeyID?; let generation: UInt64 }` (immutable, by-value).
- `enum AdmissionResult { case admitted, rejected }`.
- `struct RevokeReceipt { let lease: RevokeLease; let evictedCount: Int }` (public); `RevokeLease` opaque comparable token.
- `HostControl.admissionTicket(for: ClientKeyID) -> AdmissionTicket?` — nil iff K fenced (`revoking[K] != nil`), else `AdmissionTicket(keyID: K, generation: generation[K] ?? 0)`. Pure snapshot.
- `HostControl.register(_ id:_ connection:outbound:authClass:ticket: AdmissionTicket, capability: SessionCapability) -> AdmissionResult` — keyed ticket: `guard revoking[K]==nil && ticket.generation == (generation[K] ?? 0) else return .rejected`; else insert `sessions`, insert id into `byClient[K]` (a `Set<SessionID>`), `keepAwake.sessionBegan(id)` INSIDE the lock. Legacy (`keyID==nil`) skips the fence/gen check.
- `HostControl.deregister(_ id:)` — remove from `sessions` + `byClient[keyID]` (drop empty key) + `keepAwake.sessionEnded` INSIDE the lock. Does NOT invalidate the capability (caller already did — Invalidate-First).
- `HostControl.beginRevoke(clientKeyID: K) -> RevokeReceipt` (public) — coalesce a duplicate begin (return existing receipt, no second fence); else under the lock {mint lease, `revoking[K]=lease`, `generation[K] += 1`, snapshot the `byClient[K]` sessions, unlink them, `keepAwake.sessionEnded` each}; OUT of the lock {`capability.invalidate()` FIRST, then `outbound.finish()` + `closeDiscardingInbound()` each snapshot}. Teardown internal.
- `HostControl.endRevoke(lease:)` / `cancelRevoke(lease:)` — remove K from `revoking` IFF `revoking[K]==lease` (matching-lease); generation stays bumped; stale lease no-ops. `cancelRevoke` is the same lift, the LAContext-gated durable-failure escape.
- `evictLegacyAdmitted` upgraded: under lock snapshot + keepAwake-end + remove; out of lock invalidate-FIRST + finish + `closeDiscardingInbound` (replaces the draining `close()` at `:113`).
- `disconnectAll` upgraded: under lock snapshot + `sessions.removeAll()` + **clear `byClient`** + `keepAwake.endAll()` INSIDE the lock; out of lock invalidate-FIRST each, THEN the graceful-`bye` Task (unchanged, trusted).

**Consumes:** `SessionCapability` (T1), `closeDiscardingInbound` (T2).

- [ ] **Step 1: Failing tests** — the entire §8 `HostControl registry + generation + lease-fence` list: multi-session-per-key + beginRevoke-kills-all + endRevoke-lifts; **ticket-at-auth** (gen=0 ticket registered after a gen=1 bump, even with re-enroll making isAuthorized true, is rejected at register — the §3 register-time table); **lease-fence** (fenced → admissionTicket nil + register rejects; duplicate beginRevoke coalesces; stale-lease endRevoke no-op; matching lifts; **fail-closed**: a simulated durable throw retains the fence, Retry+success lifts, cancelRevoke lifts without durable); **Invalidate-First** (deregister/evictLegacy/disconnectAll invalidate the capability BEFORE registry removal — observe order via a fake capability recording call order); deregister-by-SessionID doesn't wipe a sibling; disconnectAll clears byClient AND sessions; **keepAwake linearization** (a disconnectAll endAll racing a register never releases the new id's assertion — barrier + injected KeepAwake backend, assert balance); nil-key legacy untouched by beginRevoke.
- [ ] **Step 2:** Run `swift test --filter "HostControl|Eviction|Revoke"` — fail.
- [ ] **Step 3:** Implement per §2 `HostControl*` + §3 + §4. Update the existing `register` call site's signature ripple is Task 8's job — for THIS task, the loopback test constructs `register(...)` with the new params directly (mirror `HostControlEvictionTests`).
- [ ] **Step 4:** `swift test` green (the register signature change may break the production call site in HostRunner — if so, add a MINIMAL compile-fix passing a fresh capability + a legacy ticket there, leaving the real wiring to Task 8; note it in the report).
- [ ] **Step 5:** Commit `feat: HostControl generation registry + fenced revoke lease + invalidate-first teardown (han.4 core)`.

### Task 5: Effect-boundary capability in inbound units + size caps

**Files:** Modify `Sources/PortviewHostCore/InputInjector.swift`, `Sources/PortviewHostCore/FileReceiver.swift`, `Sources/PortviewHostCore/ClipboardSync.swift`; Test the respective host suites (mirror `InputInjectorGateTests`, decisions.md 2026-07-10 item 1, for the postEvent seam).

**Interfaces — Produces:** each takes the session `SessionCapability`. `InputInjector` routes the per-event post through `capability.perform { self.postEvent(event) }` at the `postEvent` seam (`:117-127`) — per-CGEvent, NOT whole-message. `FileReceiver.chunk` SELF-GUARDS its single `handle.write` (`:60`) via `capability.perform` (it takes the capability); the serve loop (Task 8) calls `fileReceiver.chunk(chunk)` UNWRAPPED — an outer wrap would self-deadlock the non-reentrant lock (Task-5 review). `ClipboardSync.applyRemote`'s deferred `Task { @MainActor }` wraps the single pasteboard mutation in `capability.perform { … }` (recheck INSIDE the MainActor task — closes the deferred-write-after-teardown hole, H-d/finding 3). The process-wide `InputInjector.paused` is unchanged (orthogonal). **Size caps** (H-b) are applied at the serve boundary (Task 8) — here, just accept the capability + gate at the irreducible seam.

**Consumes:** `SessionCapability` (T1).

- [ ] **Step 1: Failing tests** (§8 `Bounded-wait` + `Clipboard MainActor recheck`): a large `.typeText` gated per-CGEvent lets `invalidate` win after ONE event (assert postEvent count after invalidate via the seam); `applyRemote` with an invalidated capability does NOT mutate the fake pasteboard EVEN when the write is deferred to a MainActor task, INCLUDING when the invalidation came from a normal teardown (not a revoke); a `FileReceiver.chunk` under an invalidated capability does not write.
- [ ] **Step 2:** Run — fail.
- [ ] **Step 3:** Implement per §2 (`InputInjector`/`FileReceiver`/`ClipboardSync`). Thread the capability via each type's init/method — the concrete wiring from serveSession is Task 8; here add the parameter + the perform-gate, and the existing unit tests construct the type with a fresh valid/invalid capability.
- [ ] **Step 4:** `swift test` green.
- [ ] **Step 5:** Commit `feat: per-effect capability gate on inbound injection/file/clipboard (han.4 H-b/H-d)`.

### Task 6: Outbound capability (video/audio/lanes/sink)

**Files:** Modify `Sources/PortviewHostCore/HostRunner.swift` (`pumpVideo`+audio child, `:1006`/`:1027`), `Sources/PortviewHostCore/HostLaneRouter.swift`, `Sources/PortviewTransport/OutboundLane.swift`; Test the media/lane suites (mirror `HostLaneRoutingLoopbackTests` + a fake `LaneStreamSender`).

**Interfaces — Produces:** each takes the session `capability`. `pumpVideo`/audio/stats check `capability.isValid` IMMEDIATELY BEFORE each post-encode send (video `:1098`, audio `:1029`, stats `:1118`) and drop when invalid (today only `Task.isCancelled` is checked, and only pre-encode `:1047`). `HostLaneRouter.send` (`:156`) drops when invalid; add `closeBoundLanes()` (serve-defer-called) that sets a terminal `closed` flag AND closes retained secondary senders (`lanes`, `:48`); `bind` (`:92`) additionally guards `!closed` so a late bind racing closure is REFUSED. `OutboundLane`'s production sink (`:108-110`) gates on `capability.isValid` before `connection.send` (drops a taken-but-not-sent message if the capability flipped between `take()` and send). `finish()` unchanged; revoke/teardown call it AFTER invalidation.

**Consumes:** `SessionCapability` (T1).

- [ ] **Step 1: Failing tests** (§8 `Outbound capability`): a `pumpVideo`/router send with an invalidated capability drops (no send on the fake sender); the `OutboundLane` sink drops a taken-but-unsent message after invalidate; `router.closeBoundLanes` closes bound secondary senders AND refuses a late `bind` after close; pin the defined residual (in-flight `Network.framework` bytes out of scope) in a test-name/comment.
- [ ] **Step 2:** Run — fail.
- [ ] **Step 3:** Implement per §2 (`pumpVideo`/`HostLaneRouter`/`OutboundLane`). Thread the capability — the serve wiring is Task 8.
- [ ] **Step 4:** `swift test` green.
- [ ] **Step 5:** Commit `feat: capability-gate outbound video/audio/lanes + terminal closeBoundLanes (han.4 finding 4/H-e)`.

### Task 7: `serveAuthGate` — admission ticket capture at authorization

**Files:** Modify `Sources/PortviewHostCore/HostRunner.swift` (`serveAuthGate`, `:813`); Test extend `Tests/PortviewHostTests/AuthGateTests.swift`.

**Interfaces — Produces:** `serveAuthGate` gains a reservation seam `admissionTicket: @Sendable (ClientKeyID) -> AdmissionTicket?` (bound in prod to `control.admissionTicket`). IMMEDIATELY after `ClientAuthCrypto.verify` (`:847`) and BEFORE `pairings.authorizedClient` (`:851`): compute `K = PairingStore.deviceID(forPublicKey:)`, `guard let ticket = admissionTicket(K) else { return .rejected(.revoking) }`. On the authenticated path, the outcome carries the ticket: `.authenticated(deviceID: K, ticket: AdmissionTicket)`. Add `.revoking` to `AuthGateRejection`. (Order-A, §3/§5.)

**Consumes:** `AdmissionTicket`/`admissionTicket` (T4).

- [ ] **Step 1: Failing tests** (extend the seam-driven gate suite): an authenticated key returns `.authenticated(deviceID:ticket:)` with the ticket the seam issued; a fenced key (seam returns nil) → `.rejected(.revoking)` even with a valid signature + enrolled key; the ticket's generation is the seam's value (drive the seam to return a specific generation).
- [ ] **Step 2:** Run — fail (outcome shape change; update the existing gate tests' expectations for the new `.authenticated` associated value).
- [ ] **Step 3:** Implement per §2 `serveAuthGate` + §5.
- [ ] **Step 4:** `swift test --filter AuthGate` green; full `swift test` green.
- [ ] **Step 5:** Commit `feat: capture admission ticket at authorization (Order-A) (han.4 finding 1)`.

### Task 8: `serveSession` reorder + capability threading + CLI control minting (integration)

**Files:** Modify `Sources/PortviewHostCore/HostRunner.swift` (`serveSession` `:510`, `run` `:97`); Test extend `Tests/PortviewHostTests/AuthGateSessionTests.swift` (loopback + `onAuthGateOutcome`/`didBuildScaffolding` seams).

**Interfaces — Produces:** the §1b corrected spine — construct `SessionCapability` + an inert `OutboundLane` (no producer attached) → `register(ticket, capability)` → guard `.admitted` (else invalidate+`closeDiscardingInbound`+return) → **post-await durable recheck** `guard T.keyID==nil || await pairings.isAuthorized(T.keyID) else {invalidate+deregister+close+return}` → `didBuildScaffolding` → ONLY THEN producers (`server.handle`, lane auth, `ServerHello`, clipboard.start, cursorPump, injector) — each direct send (`ServerHello`/lock-status/pong) `isValid`-gated (H-e); the ClientHello handshake is pulled OUT of the message loop into a one-shot post-admission step; the loop starts from the SECOND message; each privileged inbound effect is **size-capped** at the serve boundary (`.typeText`/`.clipboardUpdate`=`Frame.maxClipboardBytes`/`.fileChunk`) BEFORE dispatch; the T5 effect units (`InputInjector`/`FileReceiver`/`ClipboardSync`) ALREADY SELF-GUARD at their irreducible boundary, so call them NORMALLY (no outer `capability.perform` — it would self-deadlock the non-reentrant lock, Task-5 review) after threading the ONE real per-session `capability` into them (replace the T5 placeholders); the teardown defer's FIRST statement is `capability.invalidate()`. `run` mints a process-local `HostControl` when `control == nil` and passes it non-optionally down (M-b, CLI).

**Consumes:** T1 (capability), T2 (closeDiscardingInbound), T4 (register/ticket/AdmissionResult), T5 (inbound gates), T6 (outbound gates), T7 (gate ticket outcome).

- [ ] **Step 1: Failing tests** (§8 `Admission TOCTOU + ordering`, `Direct-send gating`, `Size caps`, `CLI control minting`): a revoke between gate-authorize and register self-closes at the fence/gen check (no ServerHello, no clipboard send, didBuildScaffolding never fires); a revoke DURING the durable await self-closes at the post-await recheck (same asserts); clipboard polling + outbound producers start ONLY after the post-await recheck; with the capability invalidated during the await, NO ServerHello/lock-status fire and a pong for a post-invalidate message is dropped; an over-cap `.typeText`/inbound `.clipboardUpdate`/`.fileChunk` is skipped at the serve boundary; `run(control: nil)` mints a HostControl and serveSession registers/evicts against it (loopback seam).
- [ ] **Step 2:** Run — fail.
- [ ] **Step 3:** Implement per §1b (the explicit corrected spine) + §2 `serveSession`/`run`. This is the hardest task — reorder carefully; keep peripheral logic intact.
- [ ] **Step 4:** `swift test` green; `make build-host` SUCCEEDED; `make test-ios` SUCCEEDED (the outcome/signature changes ripple to the app — fix minimally, real app wiring is Task 9).
- [ ] **Step 5:** Commit `feat: serveSession admission-before-producers + capability threading + CLI control mint (han.4 findings 5/H-e)`.

### Task 9: SAS window-epoch lease + decision tokens (folded cleanups 6a/6b)

**Files:** Modify `Sources/PortviewHostCore/SASPairingControl.swift`, `apps/PortviewHost/Sources/HostAppModel.swift` (the SAS `.sasCode` handling + the enrollment decision flags); Test the SAS + a HostAppModel-logic suite where pure.

**Interfaces — Produces:** `registerAttempt` returns an opaque `WindowLease?`; `claimCodeDisplay` validates the window is still open under that lease; the lease threads through reveal/code/confirm; the limiter mints a fresh lease id in `open`. `.sasCode`/`.sasConfirmed` are stamped with the lease; the app applies them only when the stamp equals the current window lease (a prior window's async event can't mutate a newer window's HUD). The enrollment decision flags (`enrollmentDecisionInFlight`/`approvalInFlightID`, `HostAppModel.swift:86`/`:92`) become PER-TASK tokens (a `Set<UUID>` won't do — use per-task tokens with duplicate-start rejection, §6b/§9): a second `approveEnrollment` for an in-flight attempt is rejected (no second LAContext); each Task's defer clears ONLY its own token.

**Consumes:** none new (this is the han.3-deferred cleanup; independent of the registry).

- [ ] **Step 1: Failing tests** (§8 `Window lease` + `Decision tokens`): a `.sasCode` stamped with a prior `WindowLease` is ignored while a newer window is open; `claimCodeDisplay` rejects a claim whose lease isn't the current open window's; a second `approveEnrollment` for an attempt already in flight is rejected (no second LAContext); a stale task's defer clears only its own token.
- [ ] **Step 2:** Run — fail.
- [ ] **Step 3:** Implement per §6a/§6b. Where the decision-token logic is @MainActor-entangled, a device-gated wiring change with a clear comment is acceptable (host UI).
- [ ] **Step 4:** `swift test` green; `make build-host` SUCCEEDED.
- [ ] **Step 5:** Commit `feat: SAS window-epoch lease + per-task enrollment decision tokens (han.4 folded cleanups)`.

### Task 10: Revoke UI + shared PairingStore + revoke orchestration (macOS app, device-gated)

**Files:** Modify `apps/PortviewHost/Sources/HostAppModel.swift`, `apps/PortviewHost/Sources/MenuBarHostView.swift`; `cd apps/PortviewHost && xcodegen generate` if a file is added.

**Interfaces — Produces:** promote the inline `PairingStore()` (`HostAppModel.swift:122`) to a stored property built once (mirror stored `control`/`authority` `:49`/`:61`), passed into `events(...)` AND the revoke action. Add an `enrolledDevices` observable (from `pairings.list()`, refreshed on surface-open + after enroll/revoke) and `revoke(_ id:)` running §1a steps 2–6: confirmation dialog + `LAContext.evaluatePolicy(.deviceOwnerAuthentication)` (mandatory) → `receipt = control.beginRevoke(clientKeyID: id)` → `await pairings.revoke(id:)` → on success `control.endRevoke(receipt.lease)` + refresh; on durable FAILURE keep the row "incomplete" with Retry (re-run durable) / LAContext-gated Cancel (`control.cancelRevoke`). Menu-bar "Paired devices" view: `enrolledDevices` rows (name + fingerprint + lastSeen) with a per-row Revoke gated per decision 1; last-device copy per decision 2; a durable-failure row shows Retry/Cancel. Mirror `enrollmentPromptView` (`:153`) for the LAContext button, `pairingSurface` (`:98`) for placement. Fingerprint only, never raw pubkey.

**Consumes:** T4 (`beginRevoke`/`endRevoke`/`cancelRevoke`/`RevokeReceipt`), T3 (`list`).

- [ ] **Step 1:** Wire the shared `PairingStore` stored property + `enrolledDevices` snapshot; verify `make build-host` compiles with the shared instance passed to `events(...)`.
- [ ] **Step 2:** Implement `revoke(_ id:)` (confirm → LAContext → begin → durable → end/retain) + the durable-failure Retry/Cancel branch.
- [ ] **Step 3:** Build the "Paired devices" view + per-row Revoke + last-device copy.
- [ ] **Step 4:** `xcodegen generate` (if new file); `make build-host` SUCCEEDED (UI behavior device-gated `[?]`).
- [ ] **Step 5:** Commit `feat: menu-bar revoke UI — LAContext-gated, shared PairingStore, durable-failure retry (han.4, UI device-gated)`.

### Task 11: Full verify, adversarial implementation review, docs, close

- [ ] **Step 1:** `swift test` (serial to avoid the load flake, portview-yur), `make build-host`, `make test-ios` — all green on final HEAD.
- [ ] **Step 2:** Adversarial IMPLEMENTATION review, cross-lineage: **Opus 5** (reviews the Sonnet-authored task code) + **GPT-5.6 Sol** (different lineage from Opus, reviews the whole diff incl. Opus-authored tasks) — read-only, prompt in `ai-scratch/`. Focus per the design's load-bearing invariants: Invalidate-First on every path; no-await/bounded `perform`; the out-of-lock invalidation windows R8 AND R9 (is R8 truly ≤1 irreducible effect? is R9's parked-waiter single-message residual deterministically caught by the invalidate-before-discard ordering + the per-effect capability.perform lock? is that lock genuinely the linearizer?); RevokeLease fail-closed; the serveSession reorder (nothing sent pre-recheck); touch no-resurrect. Fold verified findings TDD; re-run Step 1.
- [ ] **Step 3:** Docs: decisions.md ADR (revoke design + review dispositions + the R7/R8 residuals); current-state.md session entry; scorecard entries for Opus 5 (design ×3 + impl) and Sol (design review ×2 + impl). Update the epic root `portview-han` status.
- [ ] **Step 4:** `bd close portview-han.4 --reason "…"`; `bd close portview-han` (the epic — han.1–4 all landed) if the remaining epic scope is complete. Device-verify `[?]` items (the §8 hardware list) filed for the next device sitting.

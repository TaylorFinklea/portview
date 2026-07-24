# Design v2 — Enrollment ceremony (han.3): local-presence prompt + dual-fingerprint compare

Implements §4-RESOLVED of `2026-07-01-revocable-pairing-mutual-auth.md` (Option (a), the six
must-fixes). v2 folds the pre-implementation adversarial design review (2026-07-23, GPT-5.6 Sol:
REDESIGN + Kimi K3: BUILD-WITH-CHANGES — converged on every load-bearing change; v1 lost the
first-prompt race the ceremony exists to win). User decisions (fixed): local presence =
**LAContext/Touch ID**; migration window stays **`.distantFuture`** (first-enroll auto-promotion
is the bound); scope = **full ceremony, UI device-gated**; fingerprint = grouped hex.

## Flow (v2 — changes marked ►)

1. User opens the pairing window (menu-bar → `HostAppModel.beginPairing`).
   ► **Legacy barrier (must-fix 3, review H3/Sol-1)**: `beginPairing` first calls
   `control.evictLegacyAdmitted()`, AND while the window is open `serveSession` REFUSES new
   legacy admissions (silent peer + bootstrap + `sas.isOpen()` → close, not admit — an enrolling
   phone answers the challenge, so it is unaffected). No remote peer can watch the ceremony or
   click Deny. The approve-time evict remains as the second fence.
2. Client pairs via SAS (or QR); ► from the moment a pairing-driven connect starts, the phone
   shows a PERSISTENT compare card — "Approve on the Mac — compare: `AB12 CD34 EF56 7890 1234`"
   (its own `KeyFingerprint.short`), surviving the SAS sheet's submit and the pinned re-dial,
   until the ceremony resolves (streaming / denied / timed out / cancelled). Invariant: the
   reference is visible BEFORE the Mac prompt can exist (review H1/Sol-3). Same card on the QR
   path.
3. Pinned re-dial: `ClientHello` → `ServerChallenge` → `ClientAuth` (persistent `ClientIdentity`).
   ► Pairing-driven connects that close pre-`ServerHello` RETRY (~2 s cadence, backoff) while the
   pairing context is active — until window-close, user cancel, or an explicit denial — with
   distinct end states ("denied on the Mac" / "timed out — retry" / connected) (review H2/Sol-5).
4. Gate: unknown key + VALID signature + window open → prompt-pending. Host emits
   `.enrollmentRequest(attemptID:fingerprint:claimedName:expiresAt:)` (► carries `expiresAt`; no
   key material — the authority holds the snapshot).
5. macOS prompt: "A device calling itself 'X' — fingerprint `AB12 CD34 …` — compare ALL FIVE
   groups with the phone" (► full-compare copy, both surfaces; review fingerprint caveat).
   Allow → `LAContext.evaluatePolicy(.deviceOwnerAuthentication)` → `authority.approve(attemptID)`.
6. Gate on approval: ► re-check `sas.isOpen()` (a cap-exhaustion close invalidates), then
   `pairings.enroll(exact snapshot, sanitizedName)` — ► **enroll-throw fails CLOSED**: consume
   the attempt, close the connection, never `ServerHello`, emit a distinct error event (review
   M1/Sol-8) — then `control.evictLegacyAdmitted()` (eager; ► non-optional in the ceremony path)
   → proceed to `ServerHello` as `.authenticated`.
7. Deny / 25 s timeout / window-close / connection-death → ► request invalidated on ALL paths
   (single-resume continuation, entry removed), silent close, source blocked for the window.
   ► `.enrollmentResolved(attemptID, outcome)` event so a lingering prompt can't false-succeed
   (approve-after-deadline is a no-op AND the UI is told; review L1).

## Units (v2 deltas marked ►)

**`KeyFingerprint` (PortviewProtocol):** `short(forPublicKey:) -> String` = first 10 bytes of
`SHA256(publicKey)` as 5 × 4-hex groups (80 bits; ~2^80 targeted second-preimage — confirmed by
both reviewers). Frozen KAT + prefix-of-`PairingStore.deviceID` KAT (host/client drift killer).

**`DeviceNameSanitizer` (PortviewHostCore):** strip C0/C1 + bidi/format controls (U+200E/F,
U+202A–E, U+2066–69, U+061C), collapse whitespace, truncate 64, fallback "(unnamed device)".
► Sanitized ONCE at serveSession entry and used EVERYWHERE the name flows: the enrollment event,
`enroll` (persisted — han.4's revoke UI renders it), and `.deviceConnected` (fixes the
pre-existing raw-name card; review L4/Sol-9).

**`EnrollmentAuthority` (actor, PortviewHostCore):**
- `EnrollmentRequest`: `{attemptID: UUID, publicKey: Data (exact snapshot), fingerprint,
  claimedName (sanitized), source, createdAt, ► expiresAt}`.
- `begin(...) -> EnrollmentRequest?` — nil if a request is pending, the source is blocked, ► the
  per-window request cap (5) is exhausted, or the window is closed.
- `awaitDecision(_ attemptID:) async -> Bool` — parked continuation; ► SINGLE-RESUME, entry
  removed on every exit (approve / deny / 25 s deadline / `windowClosed()` / task cancellation /
  ► connection-death via the caller's `withTaskCancellationHandler`). Timeout blocks the source
  (must-fix 5) — DOCUMENTED as load-bearing against re-prompt grinding; the ≤25 s slot wedge on a
  mid-prompt client death is the accepted cost.
- `approve/deny(_ attemptID:)` — approve atomically consumes exactly THAT attempt.
- ► Window ownership is SINGLE: `sas.isOpen()` (the `SASAttemptLimiter`) IS the window; the gate
  consults it at begin AND at approve; `HostAppModel.endPairing`'s existing single fan-out adds
  `authority.windowClosed()` (review M2/Sol-4).
- ► Source key: reuse `SASPairingControl.sourceKey` with IPv4 link-local (169.254/16) bucketed as
  ONE source (rotation bound, review L3); the /64 + attended-window bounds are otherwise accepted.

**Gate change (`HostRunner`):** `serveAuthGate` stays pure; `.rejected(.unknownKey)` becomes
outcome `.unknownKey(publicKey: [UInt8])`. ► HYGIENE: the new case is never stringified into
logs/events — reason codes only, fingerprint at most; a test asserts no key bytes appear (review
M3/Sol-9). `serveSession` orchestrates the ceremony on that outcome; ► works identically under
`.required` (second-device enrollment post-promotion — pinned by test) and with the window closed
or no authority (CLI) behaves exactly as today (instant close).
► Legacy barrier: in bootstrap mode with `sas.isOpen()`, a silent-peer timeout → close (not
legacyAdmitted).

**Must-fix 6 (HUD code pin):** ► claim moves BEFORE the `SASHostReveal` send (a losing preamble
closes pre-reveal, so the losing phone never derives/awaits an undisplayed code — review
L2/Sol-6); release in the preamble's defer; ► `openWindow()` force-releases any stale claim
(window-epoch semantics).

**Client (PortviewClientCore + iOS app):**
- Pure `ChallengeResponse.make(identity:challenge:pinnedCertHash:) -> ClientAuth?` — ► takes the
  immutable pin BYTES the connection actually dialed with (not re-read mutable hex state; Sol-7).
- `SessionViewModel`: identity loaded once (thrown keychain read aborts the attempt, never mints);
  handles `.serverChallenge` in the session loop; ► owns the persistent `enrollmentCompare`
  published state (the card in step 2) and the ► bounded pairing-retry loop (step 3).
- ► The compare card + retry are SessionViewModel-scoped, NOT tied to `SASClientCoordinator.state`
  (which tears down pre-re-dial).

**Host UI (macOS app, device-gated):** `.enrollmentRequest` → prompt with fingerprint +
"a device calling itself X" + full-compare copy; Allow gated by LAContext; Deny plain;
► `.enrollmentResolved` clears the prompt (expiry/deny/win); ► `beginPairing` runs the legacy
barrier before exposing pairing UI. Authority constructed beside the app's `PairingStore`, passed
through `run`/`events`.
► CLI (nil authority): DOCUMENTED semantics — existing-enrolled-devices only; enroll via the app;
a long-running CLI does not see new enrollments until restart (warm cache; per-process actors over
one keychain item — han.4's cross-process authority owns the real fix; review M4/Sol-10).

## Known residuals (explicit, not silent)

- han.3 ACTIVATES the han.4-deferred in-flight admission TOCTOU (promotion becomes reachable):
  a connection between gate-admit and register can survive the eager sweep until the next lazy
  sweep. Bounded by the window-open legacy barrier; han.4's generation-bound admission +
  register-then-recheck owns the close-out.
- `evictLegacyAdmitted`'s close can still drain already-buffered input (transport drains on
  close) — han.4's capability-invalidation-before-close (spec revocation §) owns it.
- The park-vs-close timing difference is a window-open oracle (reachable only after a valid
  signature); accepted — window state is not a secret.

## Testing

Pure/TDD: `KeyFingerprintTests` (frozen KAT + prefix-of-deviceID), `DeviceNameSanitizerTests`,
`EnrollmentAuthorityTests` (single-pending, exact-consume, expiry, cap, source-block incl.
link-local bucketing, windowClosed invalidation, single-resume on every exit),
`SASPairingControl` claim-before-reveal + window-epoch release, `ChallengeResponseTests`,
serveSession ceremony tests (approve→enrolled+evicted+authenticated; enroll-THROW→closed+
not-enrolled+no-scaffolding; deny/timeout→silent close+source-block+resolved-event; window
closed mid-prompt→invalidated; `.required`-mode ceremony works; legacy-barrier: silent peer +
open window→closed; no key bytes in any log/event). Adversarial review (Sol + K3) pre-commit.
Device-verify `[?]`: both UI surfaces + end-to-end pair→compare→allow→stream + deny + second-
device-post-promotion on hardware.

## Out of scope (owned elsewhere)

In-flight admission TOCTOU close-out, cross-process authority, revoke UI, rotation ceremony
(han.4); mTLS upgrade (future).

## Implementation addendum (2026-07-23, shipped + triple-reviewed)

Implemented via SDD (10 tasks) + a 4-commit final-review fix wave (`a3caf46..e3eb46c`). Final
adversarial implementation review: Sol×2 (RETURN, converging) + GLM-5.2 (SHIP-WITH-FIXES); Kimi K3
was weekly-capped. All load-bearing findings folded (see decisions.md 2026-07-23). Headline fix
beyond v2: the auth gate re-evaluates `effectiveMode` AT the timeout decision, not just the window
state — v2/Task-5 closed the window-state TOCTOU but left the bootstrap/required MODE sampled at
gate entry, a first-enrollment-promotion race. Deferred to han.4 (its epoch/registry): base
gate-admit→register admission TOCTOU, full SAS window-epoch binding, attempt-scoping the host
in-flight decision flags. Deny/timeout stays a silent close (no-oracle design tradeoff).

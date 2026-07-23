# Design — Enrollment ceremony (han.3): local-presence prompt + dual-fingerprint compare

Implements §4-RESOLVED of `2026-07-01-revocable-pairing-mutual-auth.md` (Option (a), the six
must-fixes). This doc covers the han.3 implementation architecture only; the security rationale
lives in the parent spec. User decisions (2026-07-23): local presence = **LAContext/Touch ID**;
migration window stays **`.distantFuture`** (first-enroll auto-promotion is the bound, per han.1's
durable marker); scope = **full ceremony, UI device-gated**. Fingerprint encoding = grouped hex
(user-confirmed).

## Flow

1. User opens the pairing window (existing menu-bar flow → `SASPairingControl.openWindow`).
2. Client pairs via SAS; on match re-dials pinned (existing) and now RESPONDS to the auth gate:
   `ClientHello` → `ServerChallenge` → `ClientAuth` signed with its persistent `ClientIdentity`.
3. Gate: unknown key + VALID signature + window open → **prompt-pending**, not close. Host emits
   an enrollment request (attemptID + fingerprint + sanitized claimed name).
4. macOS prompt shows: “A device calling itself ‘X’ — fingerprint `AB12 CD34 EF56 7890 1234`”.
   The phone’s pairing sheet shows ITS OWN fingerprint; the human compares (must-fix 2).
5. Allow → `LAContext.evaluatePolicy(.deviceOwnerAuthentication)` (must-fix 3) → the gate enrolls
   the EXACT pubkey byte-snapshot captured at prompt-render (must-fix 1), eagerly evicts
   legacy-admitted sessions, proceeds to `ServerHello`. Deny/timeout/window-close → silent close +
   the source is blocked for the window (must-fix 5).

## Units

**`KeyFingerprint` (PortviewProtocol — shared derivation, host and client must agree):**
`short(forPublicKey:) -> String` = first 10 bytes of `SHA256(publicKey)` as 5 × 4-hex-char groups
(80 displayed bits, must-fix 2). Frozen KAT. Distinct from `PairingStore.deviceID` (full hash, id)
— the fingerprint is a human-compare VIEW derived from the same hash; a KAT pins prefix-of-id.

**`DeviceNameSanitizer` (PortviewHostCore):** strip C0/C1 controls, bidi/format controls
(U+200E/F, U+202A–E, U+2066–69, U+061C), collapse whitespace, truncate (64), fallback “(unnamed
device)”. Display-only; never identity (must-fix 4).

**`EnrollmentAuthority` (actor, PortviewHostCore):** the single-request-per-window state machine
(must-fixes 1, 5).
- `EnrollmentRequest`: `{attemptID: UUID, publicKey: Data (exact snapshot), fingerprint, claimedName
  (sanitized), source (SASPairingControl.sourceKey), createdAt}`.
- `begin(publicKey:claimedName:source:now:) -> EnrollmentRequest?` — nil if a request is already
  pending, the source is blocked, or the window is closed at authority level.
- `awaitDecision(_ attemptID:, deadline:) async -> Bool` — continuation the gate parks on.
- `approve(_ attemptID:) / deny(_ attemptID:)` — approve atomically consumes exactly THAT attempt
  (stale/unknown UUIDs are no-ops); deny/timeout/`windowClosed()` invalidate + block the source for
  the window. Prompt deadline 25 s (inside the ~30 s QUIC idle so the parked connection survives).

**Gate change (`HostRunner`):** `serveAuthGate` stays pure crypto+store; its `.rejected(.unknownKey)`
becomes outcome `.unknownKey(publicKey: [UInt8])`. `serveSession` (which already holds `sas`,
`pairings`, `control`, `emit`, and the ClientHello) orchestrates the ceremony on that outcome:
window open + authority present → `begin` + emit `.enrollmentRequest(...)` (new `HostRunnerEvent`
case; carries NO key material — approval is by attemptID; the authority holds the snapshot) →
`awaitDecision` → approved: `pairings.enroll(snapshot)` + `control?.evictLegacyAdmitted()` (the
eager hook) + continue as authenticated; else close silently. No authority (CLI) or closed window →
close exactly as today. Rejection stays oracle-free: the prompt path is only reachable AFTER a
valid signature (han.1 note 4 satisfied by construction).

**Must-fix 6 (HUD code pin):** `SASPairingControl` gains `claimCodeDisplay(source:) -> Bool` /
`releaseCodeDisplay(source:)`; `serveSASPreamble` claims before `emit(.sasCode)` (skips the emit if
another preamble holds the slot — its attempt still counts against caps) and releases in its defer.

**Client responder (PortviewClientCore + iOS app):**
- Pure `ChallengeResponse.make(identity:challenge:pinnedCertHashHex:) -> ClientAuth?` (nil on
  malformed pin hex; signs `nonce ‖ pin` via `ClientIdentity.sign`).
- `SessionViewModel`: loads `ClientIdentity` ONCE (launch/first-connect; a thrown keychain read
  aborts the connect attempt — NEVER mints, per han.2; retried next connect), handles
  `.serverChallenge` in the session loop by sending the response. Retry-safe: a gate-timeout close
  falls into the existing reconnect flow.
- Pairing sheet displays `KeyFingerprint.short(forPublicKey: identity.publicKey)` (device-gated).

**Host UI (macOS app, device-gated):** `HostAppModel` handles `.enrollmentRequest` → published
prompt state → Allow (LAContext, then `authority.approve`) / Deny buttons in the menu-bar UI. The
authority instance is constructed by the app beside its `PairingStore` and passed through
`run`/`events` (new optional param; CLI passes nil → no ceremony, documented).

## Testing

Pure/TDD: `KeyFingerprintTests` (frozen KAT, format), `DeviceNameSanitizerTests` (bidi/control/
truncate), `EnrollmentAuthorityTests` (single-pending, exact-attempt consume, deny/timeout blocks
source, window-close invalidates), `SASPairingControl` code-display pin, `ChallengeResponseTests`,
gate/serveSession ceremony tests (seam-driven + loopback: approve→enrolled+evicted+authenticated;
deny→closed+not-enrolled; closed window/no authority→instant close; event carries sanitized name).
Adversarial review (Sol + Kimi K3) pre-commit. Device-verify `[?]`: the two UI surfaces + the
end-to-end pair→prompt→compare→allow→stream ceremony on real hardware.

## Out of scope (owned elsewhere)

In-flight admission TOCTOU + cross-process authority + revoke UI (han.4); rotation ceremony
(han.4); mTLS upgrade (future bead).

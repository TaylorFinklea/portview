# Enrollment Ceremony (han.3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the mutual-auth enrollment ceremony (design v2, `docs/superpowers/specs/2026-07-23-enrollment-ceremony-design.md`): host-local Allow prompt with LAContext + dual-fingerprint compare, wired into the existing auth gate, with the client challenge-responder, persistent compare card, and bounded pairing retry.

**Architecture:** Pure units first (`KeyFingerprint`, `DeviceNameSanitizer`, `EnrollmentAuthority`, `ChallengeResponse`), then host wiring (gate outcome + serveSession ceremony + events), then the two app surfaces (device-gated). Every security decision is already fixed by design v2 — implementers follow it exactly; deviations require stopping.

**Tech Stack:** Swift 6 / swift-testing (`@Suite`/`@Test`/`#expect`), SwiftPM package + xcodegen app projects, CryptoKit, LocalAuthentication (app only).

## Global Constraints

- TDD strictly: every step's test is written and seen failing before its implementation (repo norm).
- Never log/emit key bytes, nonces, or SAS codes; reason codes + fingerprint at most (decisions.md 2026-07-22 #7).
- Tests never touch live system surfaces (memory `test-live-side-effects`): no keychain in `swift test`, no LAContext in tests, injected stores/seams only.
- New app-target files require `xcodegen generate` in the app dir (memory `fresh-machine-bootstrap`).
- All work verified by: `swift test` green, `make build-host` SUCCEEDED, `make test-ios` SUCCEEDED.
- One commit per task; do not push.
- If a design-v2 requirement can't be met as written, STOP and flag — don't improvise (security feature).

---

### Task 1: KeyFingerprint (shared human-compare view)

**Files:**
- Create: `Sources/PortviewProtocol/KeyFingerprint.swift`
- Test: `Tests/PortviewProtocolTests/KeyFingerprintTests.swift`

**Interfaces:**
- Produces: `public enum KeyFingerprint { public static func short(forPublicKey: Data) -> String }`
  — first 10 bytes of SHA256(publicKey), uppercase hex, grouped `XXXX XXXX XXXX XXXX XXXX`.

- [ ] **Step 1: Failing tests.** In `KeyFingerprintTests.swift` (mirror `ClientAuthCryptoTests` style: `import Testing`, `@testable import PortviewProtocol`, CryptoKit):
  - `frozenVector`: `KeyFingerprint.short(forPublicKey: Data(1...32))`… generate the frozen expected ONCE via a scratch swift script (pattern: han.2's vecgen — SHA256 of the fixed 32-byte pubkey bytes `0x01...0x20` — note: hash the RAW BYTES as given; this test fixes the FORMAT, not a keypair) and hard-code it. Assert exact string equality.
  - `formatIs5GroupsOf4UppercaseHex`: regex `^[0-9A-F]{4}( [0-9A-F]{4}){4}$`.
  - `isPrefixOfDeviceID`: `KeyFingerprint.short(...).replacingOccurrences(of: " ", with: "").lowercased()` == `String(PairingStore.deviceID(forPublicKey:).prefix(20))`. Requires adding `PortviewTransport` to `PortviewProtocolTests` deps? NO — PortviewProtocol must not depend on Transport. Instead put THIS one cross-module test in `Tests/PortviewTransportTests/PairingStoreTests.swift` (which already imports both) as `fingerprintIsPrefixOfDeviceID`.
- [ ] **Step 2: Run `swift test --filter KeyFingerprint` — expect compile failure (type missing).**
- [ ] **Step 3: Implement** `KeyFingerprint.short`: SHA256 via CryptoKit, take 10 bytes, format `%02X` pairs, insert a space every 4 hex chars. ~10 lines.
- [ ] **Step 4: Run `swift test --filter "KeyFingerprint|PairingStore"` — all green.**
- [ ] **Step 5: Commit** `feat: KeyFingerprint 80-bit human-compare view (han.3 design v2)`.

### Task 2: DeviceNameSanitizer

**Files:**
- Create: `Sources/PortviewHostCore/DeviceNameSanitizer.swift`
- Test: `Tests/PortviewHostTests/DeviceNameSanitizerTests.swift`

**Interfaces:**
- Produces: `enum DeviceNameSanitizer { static func sanitize(_ name: String) -> String }` (internal).

- [ ] **Step 1: Failing tests:** strips C0/C1 controls; strips bidi/format chars (U+200E, U+200F, U+202A–U+202E, U+2066–U+2069, U+061C); collapses runs of whitespace to one space + trims; truncates to 64 characters (by `Character` count); empty/whitespace-only → `"(unnamed device)"`; a normal name passes through unchanged.
- [ ] **Step 2: Run — expect compile failure.**
- [ ] **Step 3: Implement** via `unicodeScalars.filter` against a `CharacterSet` of the banned scalars + `generalCategory` control check, then whitespace collapse + prefix(64).
- [ ] **Step 4: Green.**
- [ ] **Step 5: Commit** `feat: DeviceNameSanitizer — display/persist hygiene for claimed names (must-fix 4)`.

### Task 3: EnrollmentAuthority actor

**Files:**
- Create: `Sources/PortviewHostCore/EnrollmentAuthority.swift`
- Test: `Tests/PortviewHostTests/EnrollmentAuthorityTests.swift`

**Interfaces:**
- Produces (all on `actor EnrollmentAuthority`, internal-or-public per use below; `public init`):
  - `struct EnrollmentRequest: Equatable, Sendable { let attemptID: UUID; let publicKey: Data; let fingerprint: String; let claimedName: String; let source: String; let createdAt: Date; let expiresAt: Date }`
  - `func begin(publicKey: Data, claimedName: String, source: String, now: Date) -> EnrollmentRequest?` — nil if: a request is pending, source blocked, window request-cap (5) exhausted, or `windowClosed()` was the last window event. Captures the exact `publicKey` snapshot; `fingerprint = KeyFingerprint.short(forPublicKey:)`; `expiresAt = now + 25`.
  - `func awaitDecision(_ attemptID: UUID) async -> Bool` — parks a continuation; resolves exactly once via approve/deny/internal 25 s deadline/`windowClosed()`/cancellation. Deny + deadline + windowClosed also block the source for the window and clear pending.
  - `public func approve(_ attemptID: UUID)` / `public func deny(_ attemptID: UUID)` — exact-attempt; stale/unknown UUID = no-op.
  - `func windowOpened()` / `public func windowClosed()` — window epoch: opened resets blocks + cap + clears any stale pending (resolving its continuation false).
- Consumes: `KeyFingerprint` (Task 1). Timeout uses an injectable `now: () -> Date`? NO — the 25 s deadline must fire for a PARKED await; use `Task.sleep` raced via the same `SingleResumeGate` pattern as `MessageReader.next(deadline:)` (HostRunner.swift — find `SingleResumeGate`, mirror it). Tests pass a short `deadline: Duration` (init parameter, default `.seconds(25)`).

- [ ] **Step 1: Failing tests** (all async, no wall-clock flakiness — deadline injected at `.milliseconds(80)` where needed):
  - `beginCapturesSnapshotAndFingerprint` (fields exact; mutate the caller's Data after — request unchanged).
  - `secondBeginWhilePendingIsNil`; `beginAfterResolutionWorks`.
  - `approveExactAttemptReturnsTrue` (begin → concurrent awaitDecision → approve(id) → await returns true).
  - `approveWrongUUIDIsNoOp` (await still resolves false at deadline).
  - `denyBlocksSourceForWindow` (deny → begin(same source) nil; begin(other source) OK).
  - `deadlineBlocksSourceAndResolvesFalse`.
  - `windowClosedInvalidatesPendingAndBlocks`; `windowOpenedResetsBlocksCapAndStalePending`.
  - `requestCapPerWindow` (5 begins+resolutions → 6th nil; windowOpened resets).
  - `singleResume` (approve then deny then deadline → awaitDecision returned exactly once, true).
- [ ] **Step 2: Run — compile failure.**
- [ ] **Step 3: Implement.** Actor state: `pending: (request, continuation)?`, `blockedSources: Set<String>`, `requestsThisWindow: Int`, `windowOpen: Bool`. Deadline: on `awaitDecision`, spawn a `Task.sleep(deadline)` that calls an internal `timeout(attemptID)`; every resolution path checks it still owns the pending attempt (single-resume by construction inside the actor).
- [ ] **Step 4: Green (`swift test --filter EnrollmentAuthority`).**
- [ ] **Step 5: Commit** `feat: EnrollmentAuthority — single-request-per-window ceremony state machine (must-fixes 1,5)`.

### Task 4: SASPairingControl — HUD code claim + link-local bucketing

**Files:**
- Modify: `Sources/PortviewHostCore/SASPairingControl.swift` (actor; `sourceKey` at ~:80-97)
- Modify: `Sources/PortviewHostCore/HostRunner.swift` (`serveSASPreamble` — host reveal send at ~:841, `emit(.sasCode)` at ~:843)
- Test: `Tests/PortviewHostTests/SASAttemptLimiterTests.swift` (sourceKey cases live here) + new claim tests in a `SASCodeDisplayClaimTests` suite in the same file’s pattern

**Interfaces:**
- Produces: on `SASPairingControl`: `func claimCodeDisplay(source: String) -> Bool`, `func releaseCodeDisplay(source: String)`; `openWindow` force-releases any held claim.
- `sourceKey` change: IPv4 addresses in `169.254.0.0/16` all return the single bucket `"169.254.0.0/16"`.

- [ ] **Step 1: Failing tests:** first claim true / second (different source) false until release; release by NON-owner is a no-op; `openWindow()` releases a stale claim; link-local `169.254.1.2` and `169.254.9.9` produce the same sourceKey, and a routable IPv4 is unchanged.
- [ ] **Step 2: Run — fail.**
- [ ] **Step 3: Implement** (actor-isolated `codeDisplayOwner: String?`; sourceKey guard for the 169.254 prefix before the generic IPv4 return).
- [ ] **Step 4: Wire `serveSASPreamble`:** move the claim BEFORE the `SASHostReveal` send: claim fails → `return` (connection closes, losing client never derives a code — design v2 must-fix 6); install `defer { Task { await sas?.releaseCodeDisplay(source:) } }`-style release immediately after a successful claim (find the existing `sas`/source derivation at the preamble entry; mirror how `registerAttempt` gets its source). Only emit `.sasCode` when the claim is held (guaranteed by ordering now).
- [ ] **Step 5: Full `swift test --filter "SAS"` green (SAS preamble loopback suite must stay green — it exercises this path end-to-end).**
- [ ] **Step 6: Commit** `feat: HUD code display claim before host reveal + link-local source bucketing (must-fix 6, review L2/L3)`.

### Task 5: Gate outcome `.unknownKey(publicKey:)` + window-open legacy barrier

**Files:**
- Modify: `Sources/PortviewHostCore/HostRunner.swift` (`AuthGateOutcome`, `serveAuthGate`, `serveSession` gate-call region ~:530-560, rejection logging ~:549)
- Test: `Tests/PortviewHostTests/AuthGateTests.swift`, `Tests/PortviewHostTests/AuthGateSessionTests.swift`

**Interfaces:**
- Produces: `AuthGateOutcome.unknownKey(publicKey: [UInt8])` replaces `.rejected(.unknownKey)` (delete the `AuthGateRejection.unknownKey` case). `serveAuthGate` gains `sasWindowOpen: Bool` parameter; in `.bootstrap` mode with `sasWindowOpen == true`, a TIMEOUT returns `.rejected(.timeout)` (NOT `.legacyAdmitted`) — the legacy barrier.
- Consumes: existing gate/tests from han.1.

- [ ] **Step 1: Failing tests:**
  - Update `validSignatureFromUnknownKeyIsRejected` → `validSignatureFromUnknownKeyReturnsKeySnapshot`: outcome is `.unknownKey(publicKey: Array(key.publicKey.rawRepresentation))`.
  - New `silentPeerUnderBootstrapWithWindowOpenIsClosed`: mode `.bootstrap`, `sasWindowOpen: true`, silent → `.rejected(.timeout)`.
  - Existing `silentClientIsLegacyAdmittedUnderBootstrap` passes `sasWindowOpen: false`.
  - New hygiene test in `AuthGateSessionTests`: drive the loopback unknown-key path and assert no emitted `HostRunnerEvent`'s `String(describing:)` contains the pubkey hex (serveSession, with NO authority, must close without emitting anything key-bearing).
- [ ] **Step 2: Run — compile failures + reds.**
- [ ] **Step 3: Implement:** outcome case change; gate takes `sasWindowOpen`; serveSession passes `await sas?.isOpen() ?? false`; the serveSession switch handles `.unknownKey`: for now (authority arrives Task 6) close exactly as before but log ONLY `"auth gate: unknown key (fingerprint <KeyFingerprint.short>)"` — never the reason enum with payload.
- [ ] **Step 4: Full `swift test --filter AuthGate` green; run the two AuthGateSession loopback suites.**
- [ ] **Step 5: Commit** `feat: gate returns unknown-key snapshot + window-open legacy barrier (design v2 H3, hygiene M3)`.

### Task 6: serveSession ceremony orchestration + events + name sanitize-once

**Files:**
- Modify: `Sources/PortviewHostCore/HostRunner.swift` (`HostRunnerEvent` enum ~:36-54; `serveSession`; `serve`; `run`/`events` signatures ~:70-95; `.deviceConnected` emit ~:676)
- Test: `Tests/PortviewHostTests/AuthGateSessionTests.swift` (extend) — ceremony is loopback-testable end-to-end with a scripted approver.

**Interfaces:**
- Produces:
  - `HostRunnerEvent.enrollmentRequest(attemptID: UUID, fingerprint: String, claimedName: String, expiresAt: Date)` and `.enrollmentResolved(attemptID: UUID, approved: Bool)`.
  - `serve`/`serveSession`/`run`/`events` gain `enrollment: EnrollmentAuthority? = nil`.
  - Ceremony (in serveSession, on `.unknownKey(publicKey:)`): requires `enrollment != nil` AND `await sas?.isOpen() == true` AND `control != nil` (design: non-optional dependencies where enrollment can occur — if `control == nil`, close, no ceremony); `source = SASPairingControl.sourceKey(for: connection.resolvedRemoteEndpoint)`; name sanitized ONCE from the held ClientHello (`DeviceNameSanitizer.sanitize(hello.deviceName)`) and reused for the event, `enroll`, and `.deviceConnected`; `begin` nil → close; emit `.enrollmentRequest`; `await enrollment.awaitDecision(attemptID)`; on true → re-check `await sas?.isOpen() == true` else treat as deny → `try pairings.enroll(publicKey: Data(snapshot), deviceName: sanitized)` — CATCH → emit `.enrollmentResolved(approved: false)` + `.message("Enrollment failed — keychain unavailable…")`, close, return (fail closed, no ServerHello) → on success `control.evictLegacyAdmitted()`, emit `.enrollmentResolved(approved: true)`, proceed with `sessionAuthClass = .authenticated` into the existing loop. On false → emit `.enrollmentResolved(approved: false)`, close.
  - `.deviceConnected` name becomes the sanitized one.
- Consumes: Tasks 2, 3, 5.

- [ ] **Step 1: Failing loopback tests** (extend AuthGateSessionTests; empty DisplayRegistry as before — the ceremony resolves BEFORE the display guard, so outcomes/events are observable):
  - `ceremonyApproveEnrollsEvictsAndAuthenticates`: open window (`SASPairingControl().openWindow()`), authority with short deadline, scripted approver task (on `.enrollmentRequest` → `authority.approve(attemptID)`); pre-register a legacy session on the `HostControl` (mirror HostControlEvictionTests' loopback registration) → after ceremony: gate outcome `.authenticated(deviceID: expected)`, pairings.isAuthorized true, legacy session gone from `activeSessionIDs()`, events contain request+resolved(true), claimedName in the event is the SANITIZED form (client sends a name with a bidi char).
  - `ceremonyDenyClosesSilentlyAndBlocksSource`: deny → no ServerHello (client inbound ends), NOT enrolled, resolved(false) emitted, a second immediate attempt from the same client gets NO `.enrollmentRequest` (source blocked).
  - `ceremonyEnrollThrowFailsClosed`: PairingStore backed by a store whose `write` throws → approve → connection closes, `isAuthorized` false, `didBuildScaffolding` never fired, resolved(false).
  - `noAuthorityOrClosedWindowClosesAsToday`: window closed → no events, closed.
  - `ceremonyWorksUnderRequiredMode`: enroll device A first (auto-promotes), then run the ceremony for device B with the window open under `.required` → B enrolls.
- [ ] **Step 2: Run — reds.**
- [ ] **Step 3: Implement per the Interfaces block. Keep the ceremony code in a private helper `runEnrollmentCeremony(...) async -> Bool` next to `serveAuthGate` so serveSession stays readable.**
- [ ] **Step 4: Green: `swift test` FULL suite (events enum change may touch app-side switch exhaustiveness — the app target compiles in Task 8/9; package first).**
- [ ] **Step 5: Commit** `feat: serveSession enrollment ceremony — prompt-pending, fail-closed enroll, eager evict (han.3 core)`.

### Task 7: ChallengeResponse (client pure core)

**Files:**
- Create: `Sources/PortviewClientCore/ChallengeResponse.swift`
- Test: `Tests/PortviewClientCoreTests/ChallengeResponseTests.swift`

**Interfaces:**
- Produces: `public enum ChallengeResponse { public static func make(identity: ClientIdentity, challenge: ServerChallenge, pinnedCertSHA256: Data) -> ClientAuth? }` — nil unless `pinnedCertSHA256.count == 32` (and sign-throw → nil); otherwise signs via `identity.sign(nonce: challenge.nonce, hostCertSHA256: Array(pinnedCertSHA256))`.
- Consumes: `ClientIdentity` (han.2), `ServerChallenge`/`ClientAuth`/`ClientAuthCrypto` (PortviewProtocol).

- [ ] **Step 1: Failing tests:** round-trip (make → `ClientAuthCrypto.verify` true against the same nonce+pin, publicKey matches identity); wrong-length pin (16 bytes) → nil; response binds THE challenge (verify false for a different nonce).
- [ ] **Step 2: Run — compile failure. Step 3: Implement (~12 lines). Step 4: Green. Step 5: Commit** `feat: ChallengeResponse — client signer for the auth gate (immutable pin bytes)`.

### Task 8: Client wiring — responder, compare card, bounded retry (iOS)

**Files:**
- Modify: `apps/PortviewClient/Sources/SessionViewModel.swift` (session loop ~:513; connect/`.notStreamed` region ~:411-441; find the pinned-cert Data the QUIC dial passes and capture those exact bytes for the responder)
- Modify: `apps/PortviewClient/Sources/ContentView.swift` + `apps/PortviewClient/Sources/SASPairingSheet.swift` (compare card, device-gated)
- Then: `cd apps/PortviewClient && xcodegen generate`

**Interfaces:**
- Consumes: `ChallengeResponse` (Task 7), `ClientIdentity.loadOrCreate(store: KeychainClientIdentityStore())` (han.2), `KeyFingerprint` (Task 1).
- Produces (app-internal): `SessionViewModel.enrollmentCompare: String?` published while a pairing-driven connect is in flight; a bounded retry for pairing-driven pre-`ServerHello` closes.

- [ ] **Step 1: Responder.** In the session loop add `case .serverChallenge(let challenge):` → identity loaded ONCE per app session (lazy `Result`-cached; a thrown keychain read ABORTS this connect attempt — never mint mid-flow, never retry-mint; surface "device identity unavailable — unlock and retry"); send `.clientAuth(...)` from `ChallengeResponse.make(identity:challenge:pinnedCertSHA256:)` (nil → abort attempt). The pin bytes: capture the exact `Data` used by this connection's pinned dial (find the dial call; do NOT re-read mutable published hex state).
- [ ] **Step 2: Compare card.** `enrollmentCompare = KeyFingerprint.short(forPublicKey: identity.publicKey)` set when a PAIRING-driven connect begins (SAS match re-dial AND QR path), cleared on: streaming starts, explicit denial, retry exhaustion, user cancel. UI: keep the SAS sheet visible post-submit showing "Approve on the Mac — compare ALL FIVE groups: `XXXX …`" (mirror the sheet's existing state-driven presentation; drive it from `enrollmentCompare`, NOT `sasPairing`), and show the same line on the QR connecting view.
- [ ] **Step 3: Bounded retry.** Where `.notStreamed` currently exits: if `enrollmentCompare != nil` (pairing context active), retry the dial after 2 s, doubling to max 8 s, up to 6 attempts or until the card clears; distinct end states per design v2 step 3. Mirror the existing `reconnectLoop`'s structure — do not duplicate its internals.
- [ ] **Step 4: Verify:** `xcodegen generate`, `make test-ios` TEST SUCCEEDED (responder pure logic is Task-7-tested; this task's wiring is compile+sim-suite verified, behavior device-gated `[?]`).
- [ ] **Step 5: Commit** `feat: client challenge responder + persistent compare card + bounded pairing retry (han.3, UI device-gated)`.

### Task 9: Host app — authority, LAContext prompt, legacy barrier (macOS)

**Files:**
- Modify: `apps/PortviewHost/Sources/HostAppModel.swift` (events call ~:95; `beginPairing`/`endPairing` ~:110-140; event handler switch)
- Modify: `apps/PortviewHost/Sources/MenuBarHostView.swift` (prompt view; pairing-surface visibility currently gated at ~:55 on `sessions.count == 0` — MUST become reachable with authenticated sessions connected, or second-device enrollment is impossible; keep it hidden only while a prompt is showing)
- Then: `cd apps/PortviewHost && xcodegen generate`

**Interfaces:**
- Consumes: `EnrollmentAuthority` (public approve/deny/windowClosed), events from Task 6.
- Produces (app-internal): `HostAppModel.enrollmentPrompt: (attemptID: UUID, fingerprint: String, claimedName: String, expiresAt: Date)?` published.

- [ ] **Step 1:** Construct one `EnrollmentAuthority` beside the app's `PairingStore` (comment: ONE shared instance, per design); pass both through `events(...)`. `beginPairing`: FIRST `control.evictLegacyAdmitted()` + `authority.windowOpened()`, THEN the existing `sasControl.openWindow()` flow. `endPairing` fan-out adds `authority.windowClosed()`.
- [ ] **Step 2:** Handle `.enrollmentRequest` → set `enrollmentPrompt`; `.enrollmentResolved` → clear it (this is the L1 no-false-success path). Prompt view: fingerprint (5 groups, monospaced), "a device calling itself 'NAME'", "compare ALL FIVE groups with your phone", Allow/Deny. Allow → `LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Approve pairing this device")` → on success `await authority.approve(attemptID)`; failure/cancel → nothing (prompt stays until resolved/expired). Deny → `authority.deny(attemptID)`.
- [ ] **Step 3:** CLI (`Sources/portview-host/PortviewHostApp.swift`): add the documented comment — nil authority = existing-enrolled-devices only; enroll via the app; restart the CLI to see new enrollments.
- [ ] **Step 4:** `xcodegen generate` + `make build-host` SUCCEEDED (UI behavior device-gated `[?]`).
- [ ] **Step 5: Commit** `feat: host enrollment prompt — LAContext Allow, window-open legacy barrier (han.3, UI device-gated)`.

### Task 10: Full verify, adversarial implementation review, docs, close

- [ ] **Step 1:** `swift test` (expect ~575+/100+ green), `make build-host`, `make test-ios` — all green on final HEAD.
- [ ] **Step 2:** Adversarial IMPLEMENTATION review per session norm — GPT-5.6 Sol (max) + Kimi K3 (opencode-go; if quota-blocked, ask the user before substituting) against the live diff, read-only, prompt in `ai-scratch/`. Fold verified findings TDD; re-run Step 1.
- [ ] **Step 3:** Docs: decisions.md ADR (ceremony implementation + review dispositions); current-state.md session entry; spec/design addendum only if the implementation deviated; scorecard experience-log lines for both reviewers.
- [ ] **Step 4:** Single wrap-up commit if docs were separate; `bd close portview-han.3 --reason "…"`; update han.4 notes with anything discovered. Device-verify items filed as `[?]` (both UIs + end-to-end ceremony + deny + second-device-post-promotion) — human-gated, listed for the next device sitting.

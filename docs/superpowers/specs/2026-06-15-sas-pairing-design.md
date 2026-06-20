# Spec: 6-digit SAS pairing code (DESIGN — NOT YET IMPLEMENTED)

**Status:** design complete, **awaiting human security review before implementation** (2026-06-15).
A short alternative to typing the 64-hex cert pin for a Bonjour-discovered Mac. QR stays preferred.

## Why this design (sound, not "serve the pin")
Trust is anchored by the host's leaf-cert SHA-256 (the pin). A 6-digit code can't BE the pin (too
short). Instead use a **short-authentication-string (SAS)**: the code is derived from the *actually-
presented* cert + fresh nonces, so a MITM (who must present its own cert to terminate TLS) produces a
**different** code → the user sees a mismatch → abort. The cert hash is never transmitted; the code
leaks ~20 bits bound to fresh nonces (useless for replay).

## Construction
1. Client dials the discovered host over QUIC/TLS with an **unpinned, cert-capturing** verify block
   (trust-on-first-use transport; trust decided *after* by the SAS). Capture `leafCertSHA256`.
2. Client → `SASClientNonce { nonce: 16B }`. Host → `SASHostNonce { nonce: 16B }`.
3. Both derive: `code = HKDF<SHA256>(ikm: clientNonce‖hostNonce, salt: leafCertSHA256, info: "Portview SAS v1", L: 4)` → 4 bytes big-endian, `& 0x000F_FFFF`, `% 1_000_000`, `"%06u"`.
4. Host **displays** its code (HUD); user types it on the client.
5. **Match** → client tears down the unpinned link and **re-dials pinned** with `leafCertSHA256` (reuses the existing `connectQUIC(pinnedCertificateSHA256:)` + `connectedHostToSave` persistence — the streaming session is always pin-anchored). **Mismatch** → abort, surface "codes didn't match — possible interception".

The unpinned preamble carries ONLY the two nonce messages — never video/input/clipboard/files.

## Files (when implemented)
- `Sources/PortviewProtocol/SASCode.swift` (NEW, pure, TDD focus — CryptoKit HKDF), `MessageType` (+`sasClientNonce=20`, `sasHostNonce=21`), `Messages/SASClientNonce.swift` + `SASHostNonce.swift`, `AnyMessage.swift` + `Frame.swift` cases.
- `Sources/PortviewTransport`: `CertificatePinning.installCapturing(...)` (capture leaf SHA, `complete(true)` unconditionally), `QUICParameters.clientCapturingCert(...)`, `PortviewConnection.connectCapturingCert(to:) -> (PortviewConnection, Data)`.
- `Sources/PortviewHostCore`: `HostRunner.serveSession` handles `.sasClientNonce` (rate-limited → derive → `emit(.sasCode)` → send `.sasHostNonce`; never starts a session on the preamble conn), `HostRunnerEvent.sasCode(String)`, `SASAttemptLimiter` (NEW, sliding window + lockout).
- `apps/PortviewHost`: `HostAppModel.displayedSASCode` (cleared on connect/timeout/stop) + HUD render.
- `apps/PortviewClient`: `SessionViewModel.beginSASPairing(to:)` / `submitSASCode(_:)` + `sasPairing` state; `ContentView` discovered-host tap → SAS sheet (numeric 6-digit) replacing the 64-hex alert; `Data.hexEncoded`.

## Tests (TDD)
`SASCode.derive`: determinism; **cert-binding** (different cert → different code = the MITM-defeat
invariant); nonce sensitivity; always 6 digits; a **frozen known-answer vector** (guards the wire
contract). SAS message round-trips (tags 20/21). `SASAttemptLimiter` (injected `now`). Optional
loopback integration: both sides derive equal code + captured hash == `identity.certificateSHA256()`.

## ⚠️ MUST HUMAN-REVIEW before implementing
1. **No host-side failed-guess feedback** — the client decides locally, so the host rate-limiter
   throttles *nonce issuance*, not guesses. Decide: is 6 digits (~1e-6 per fresh nonce, non-amplifiable)
   enough, or send a rate-limited match/abort signal so the host can lock out after K mismatches, or
   bump to 7–8 digits?
2. **Modular bias** — 20-bit `% 1_000_000` is ~5% non-uniform at the top. Fine for a one-shot human
   SAS conventionally; consider rejection-sampling.
3. **Commit ordering** — client-nonce-first then host reveals; confirm no adversarial advantage vs.
   ZRTP-style hash commitment (the uncontrollable cert salt dominates, but confirm).
4. **Unpinned preamble** — guarantee NOTHING but the two nonce messages flows on the capturing
   connection; the host must refuse to start a session on it.
5. **Wire-stability** — MessageType 20/21 + the exact derivation are a frozen host↔client contract;
   the `info` string is the version tag; the known-answer test guards it.
6. **Host UI** — `displayedSASCode` must clear (timeout/on-connect/on-stop) and never be logged.

---

## SECURITY REVIEW OUTCOME (2026-06-19) — ❌ DO NOT IMPLEMENT AS SPECIFIED

Reviewed via a 4-lens adversarial pass (crypto / active-MITM / replay-downgrade-DoS / impl-vs-real-code) + a glm-5.2 steelman cross-check that tried and failed to refute the crux. **The v1 construction is broken against an active MITM** and has two structural implementation traps. Open question #3 above resolves ADVERSELY: the cert salt does NOT dominate against an active attacker.

### CRITICAL-1 — active-MITM nonce grind (the scheme does not bind) — REQUIRES REDESIGN
The SAS code is a public deterministic function `f(certHash, n_c‖n_h)` with no secret input, revealed **client-nonce-first with no commitment**. An on-path attacker M (cert_M to the client C, cert_H captured from host H) knows both cert hashes and substitutes the nonce it forwards on each leg. By the time M must send its **last** nonce to C (`n_h'`), it already knows the host's displayed target `code_H = f(h_H, n_c', n_h)`, so it **grinds ~2²⁰ candidate `n_h'` offline** (~1e6 HMAC-SHA256 ≈ **milliseconds**, no honest party involved → the issuance limiter never fires) until `f(h_M, n_c, n_h') == code_H`. The user reads H's code, types it into C, it matches with probability ≈ 1, and step 5's pin re-dial **pins C to the attacker** (cements, doesn't detect). Refuted defenses: cert-salt (M knows both salts), pin re-dial (uses the captured = attacker hash), one-code-vs-two-party-compare (equivalent), more digits (raises grind cost but stays cheap+unbounded; ordering is the bug). Host-side mismatch lockout alone is useless (M produces the *correct* code → no mismatch ever observed).

**REQUIRED FIX (necessary & sufficient): two-sided ZRTP-style commit-then-reveal.** Add `SASClientCommit{H(n_c)}` and `SASHostCommit{H(n_h)}` BEFORE either side reveals its plaintext nonce; reveals are refused until both commits are on the wire (per leg) and each reveal is checked `H(reveal)==commit`. This binds M's substituted nonce on each leg before it learns the honest nonce — residual success collapses to the intended 1/1e6. **Commitment must be on BOTH legs** (one-sided is broken: the legs are independent in the honest parties' views, so M pipelines them — complete the committed leg first, learn that nonce, then commit the other with full knowledge). Commit hash should bind the leaf-cert hash + role to prevent leg-swapping. With this, 6 digits is fine.

### CRITICAL-2 — `installCapturing` TOFU verify is one wire-up from disabling ALL pinning
The capturing verify (`complete(true)` unconditionally) must NOT live in `enum CertificatePinning` beside the strict `install`, and the throwaway connect must NOT be a `capturing: Bool` flag on `connectQUIC`/`QUICParameters.client`. A copy-paste/merge onto the streaming path silently voids every pin, and no existing test (all happy-path) would catch it. **FIX: type-level isolation** — a separate `enum` (e.g. `SASPreamblePinning`/`CertificateCapture`) + distinct `clientCapturingCert(...)` / `connectCapturingCert(to:)->(conn, Data)` APIs reachable ONLY from the pairing flow; add a NEGATIVE test that the production `QUICParameters.client` verify returns `complete(false)` on a mismatched cert.

### CRITICAL-3 — preamble must NOT flow through `serveSession`'s inbound loop
`serveSession` (HostRunner.swift:~334-353) builds `ClipboardSync` (starts pushing clipboard immediately), `FileReceiver`, `InputInjector` BEFORE the switch, and the switch (`~383-426`) handles `.startSession`(capture)/`.typeText`(inject)/`.fileOffer`/`.clipboardUpdate` with a permissive `default: break`. Adding SAS as cases here gives an **unpinned** peer the full live surface (screen capture, keystroke injection, file write, clipboard) before any match. **FIX: a separate `serveSASPreamble(connection:)`** that constructs NONE of that scaffolding, handles only `.sasClientCommit`/`.sasClientNonce`, `default:` → close (not break), and tears the connection down before the pinned re-dial. Decide preamble-vs-session by the FIRST message and LOCK the connection's role; the re-dial must confirm the pinned leaf hash == the captured hash.

### HIGH / MEDIUM (fold into the redesign)
- **Nonces MUST be CSPRNG, fresh-per-attempt, never persisted/reused** (predictable host nonce → 0 bits against an active attacker). State as a spec MUST + a "two preambles → different host nonce" test.
- **User-initiated pairing window gates the HUD code** (not connection-initiated): kills UI flicker/pre-emption and makes any lockout scoped to the open window (not remotely trippable = avoids lockout-as-DoS). Cap concurrent preamble connections; rate-limit acceptance per source.
- **Modular bias** (CRITICAL-1's `% 1_000_000` on 2²⁰ → codes 000000–048575 are 2× likely, min-entropy 19.93→19.00): derive 8 bytes then mod (bias < 2⁻⁴⁴) or rejection-sample.
- **Decision on digits/lockout**: keep **6 digits** — the bug is the ordering, not the length; the commitment is the fix. Host-side confirm/lockout = optional defense-in-depth to cap *online* retries, scope it to the pairing window. Do NOT bump digits as a substitute for the commitment.
- **Frozen known-answer test** (new test category — repo has only round-trip today): pin every serialization ambiguity (IKM order `n_c‖n_h`, salt = raw 32 bytes not hex, `info` exact UTF-8, L, which-4-bytes + big-endian + mask-after-assemble, full `HKDF.deriveKey` vs `expand`, `%06u` zero-pad compare). Wire across all 5 spots (MessageType, Messages/*, AnyMessage both halves, Frame encode+decode).
- **Secret hygiene**: `.sasCode` its own event (never wrapped in `.message`), no `print`/os_log of code/nonce/leaf-hash, `displayedSASCode` TTL + clear on streaming-connect/timeout/stop.
- **Re-dial**: own lifecycle for the preamble conn (`defer { close() }`), reset `connectedHostToSave`/`sessionPinHex`; mirror `bindConnection`/`unbindConnection` discipline; thread the captured `Data` pin straight through (or round-trip-test hex).

**Status**: design returns to author for the commit/reveal redesign (new messages `sasClientCommit`/`sasHostCommit`, two extra tiny messages + two hash checks) + the two isolation guardrails. Re-review the revised spec before implementation. QR (full-pin) path is unaffected and remains preferred.

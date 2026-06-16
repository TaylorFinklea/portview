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

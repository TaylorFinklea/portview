# Spec: 6-digit SAS pairing v2 — commit-then-reveal (DESIGN — NOT YET IMPLEMENTED)

**Status:** redesign after the 2026-06-19 security review of v1 (`2026-06-15-sas-pairing-design.md`),
which found v1 **broken against an active MITM** (offline nonce grind). This v2 SUPERSEDES the v1
construction. It still needs a re-review of THIS spec before implementation, but it is designed to
close every CRITICAL/HIGH from the v1 review. QR (full 64-hex pin) stays the preferred path and is
unaffected; this is the convenience path for a Bonjour-discovered Mac.

## Goal & threat model
Let an iPhone client **C** pair with a Bonjour-discovered Mac host **H** by typing a 6-digit code H
displays, instead of the 64-hex cert pin. Trust anchor remains the host leaf-cert SHA-256 (the pin).
**Threat:** an active on-path attacker **M** who terminates TLS toward C with its own cert (cert_M)
and dials H with cert_H — i.e. a full MITM. The scheme must make M unable to complete pairing
undetected except with probability ≈ 1/10⁶ per human-attended attempt.

## Why v1 failed (one line)
The code was a public function `f(certHash, n_c‖n_h)` revealed **client-nonce-first with no
commitment**, so M — the last to send a nonce to C — learned H's displayed code first and **ground
~2²⁰ nonces offline (~ms)** to force C's code equal. Fix = bind each nonce with a commitment BEFORE
any reveal, on BOTH legs (one-sided lets M pipeline the two independent legs).

---

## The v2 protocol — two-sided commit-then-reveal

Runs over the **unpinned cert-capturing preamble connection** (C captured `H_cert` = SHA-256 of the
leaf cert it actually connected to). The preamble carries ONLY these four messages, then is torn down.

Let `n_c`, `n_h` = 16-byte CSPRNG nonces (client/host). Domain tag `T = "Portview SAS commit v2"`
(UTF-8, exact bytes). Role byte `R`: client = `0x00`, host = `0x01`.

```
commit_c = SHA256( T ‖ 0x00 ‖ H_cert ‖ n_c )          (32 bytes)
commit_h = SHA256( T ‖ 0x01 ‖ H_cert ‖ n_h )          (32 bytes)
```

Wire sequence (strict; each step gated on the prior):
1. **C → H** `SASClientCommit{ commit_c }`.
2. **H → C** `SASHostCommit{ commit_h }`. *(H computes n_h + commit_h on receipt of M1; H must already be in an open pairing window — see Guardrail C — else it closes the connection.)*
3. **C → H** `SASClientReveal{ n_c }`. C sends this ONLY after receiving M2. H verifies `SHA256(T‖0x00‖H_cert‖n_c) == commit_c`; **mismatch → abort + close** (counts against the limiter).
4. **H → C** `SASHostReveal{ n_h }`. H sends this ONLY after M3 verifies. C verifies `SHA256(T‖0x01‖H_cert‖n_h) == commit_h`; mismatch → abort.

Then both derive the code:
```
prk8 = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: n_c ‖ n_h),
                              salt: H_cert, info: "Portview SAS v2", outputByteCount: 8)
code = (UInt64(bigEndian bytes prk8[0..8]) % 1_000_000)  formatted "%06u"
```
H **displays** `code` on its HUD (only while the pairing window is open). The user reads it off the
Mac and types it into C. **C compares** its derived `code` to the typed string (6-char compare).
- **Match** → C closes the preamble connection and **re-dials PINNED** with `H_cert`
  (`QUICParameters.client(pinnedCertificateSHA256: H_cert)`), and asserts the pinned leaf hash ==
  `H_cert`. The streaming session is thus always pin-anchored (reuses `connectQUIC` +
  `connectedHostToSave` persistence).
- **Mismatch** → abort, surface "codes didn't match — possible interception".

### Why this defeats the MITM (the binding argument)
On the C-leg (C↔M, salt = cert_M) M must send `commit_h'` (M2) **before** C reveals `n_c` (M3). On
the H-leg (M↔H, salt = cert_H) M must send `commit_c'` (M1') **before** H reveals `n_h`. So at the
moment M commits each substituted nonce (`n_h'`, `n_c'`) it has NOT yet learned the honest nonce on
that leg (the commitment hides it). M therefore fixes both of its nonces blind and cannot adapt them
after learning `n_c`/`n_h` to force `code_C == code_H`. Even if M pipelines the legs (run one fully
before the other), the *commit* on the not-yet-run leg is still owed before that leg's honest reveal,
so blindness holds on both. Residual success = collision in the code space = **1/10⁶ per attempt**,
exactly the intended SAS strength. Binding `H_cert` + role into the commit prevents leg-swap/reflection.

---

## Guardrails (each closes a CRITICAL/HIGH from the v1 review)

### A. Type-isolate the TOFU / cert-capturing path (v1 CRITICAL-2)
The capturing verify (which calls `complete(true)` unconditionally and records the leaf SHA) MUST be
**a separate type**, NOT a sibling of `CertificatePinning.install`, and MUST NOT be reachable via a
`Bool` flag on the pinned API.
- New `enum SASPreamblePinning` (own file) with `installCapturing(on:capture:)` — mirror the trust/
  chain/leaf extraction in `CertificatePinning.install` (`SecTrustCopyCertificateChain` → leaf →
  `Data(SHA256.hash(der))`), record the hash into an injected box/actor, then `complete(true)`.
- New `QUICParameters.clientCapturingCert() -> (NWParameters, capture)` and
  `PortviewConnection.connectCapturingCert(to:) -> (PortviewConnection, Data)` — DISTINCT methods,
  never a flag on `client(...)`/`connectQUIC(...)`.
- Streaming code paths may call ONLY `client(pinnedCertificateSHA256:)`.
- **Negative test (new):** the production `QUICParameters.client` verify returns `complete(false)`
  for a mismatched cert (currently untested — all pin tests are happy-path).

### B. Separate `serveSASPreamble` — never the streaming serve loop (v1 CRITICAL-3)
`serveSession` builds `ClipboardSync` (starts pushing clipboard immediately), `FileReceiver`, and
`InputInjector` BEFORE its inbound switch, and the switch starts capture / injects input / writes
files. The preamble MUST NOT touch any of that.
- Add `serveSASPreamble(connection:)` that constructs NONE of clipboard/injector/capture/file
  receiver and whose inbound handling accepts ONLY the four SAS messages; `default:` → close (not
  the streaming switch's permissive `break`).
- **Dispatch by first message + LOCK the role:** the host cannot distinguish preamble vs. session by
  TLS (it presents its identity either way), so peek the first inbound message — `.sasClientCommit`
  → preamble path (and nothing else ever on that connection); `.clientHello` → session path. Bake
  "first message decides and locks the connection's role" into code, not a comment. *(Stronger
  alternative if cheap: a distinct ALPN for the preamble so provenance is structural — note but not
  required.)*
- The preamble connection is torn down (`defer { close() }`) on every exit (match / mismatch /
  timeout / cancel) before the pinned re-dial; it is never reused for streaming.

### C. User-initiated pairing window gates the HUD (v1 HIGH — pre-emption / lockout-DoS)
The host displays a code and engages a preamble ONLY while a **user-opened pairing window** is active
(a "Pair" action on the menu-bar/HUD opens it; it times out, e.g. 60–120 s, or closes on success/stop).
- Outside the window, an inbound preamble is refused (connection closed) and never touches the UI →
  kills unsolicited-code flicker and pairing pre-emption.
- Cap concurrent preamble connections (small, e.g. ≤4) and rate-limit acceptance per source; drop
  beyond the cap without spawning a serve task (the accept path currently spawns an unbounded child
  task per connection).
- **MANDATORY window-scoped attempt cap** (both reviewers, 2026-06-19): a simple counter — after K
  failed/mismatched attempts within the open window (e.g. K=5), close the window ("too many attempts,
  re-open pairing"). This is a HARD ceiling on online ~1/10⁶ guesses and forecloses any future
  decoupling/flicker trick that out-paces human typing; it needs NO HMAC round-trip (that's the
  separate optional Guardrail E). Scoped to the OPEN window → a remote attacker can't lock out a user
  who isn't currently pairing.

### D. Nonce + secret hygiene (v1 HIGH/MED)
- `n_c`, `n_h` MUST be 16 bytes from a CSPRNG (`SystemRandomNumberGenerator`/`SecRandomCopyBytes`),
  drawn fresh per attempt, never persisted, never reused. (Predictable host nonce → 0 bits.)
- The code, nonces, and `H_cert` MUST NEVER hit `print`/os_log. `.sasCode` is its own
  `HostRunnerEvent` case, NEVER wrapped in `.message(String)` (that path is logged). No
  `CustomStringConvertible` on the SAS messages that prints nonce bytes.
- `displayedSASCode` has a hard TTL and is cleared on: streaming-connect (tie to `.deviceConnected`),
  window timeout, pairing-window close, and host stop.

### E. (OPTIONAL, phase 2) HMAC-authenticated host confirmation — defense-in-depth
The commitment is the fix and the MANDATORY window-scoped attempt cap (Guardrail C) is the hard
online-retry ceiling; THIS adds authenticated accounting on top (the host learns *which* attempts
succeeded, not just that one finished). After C decides match, C MAY send
`SASClientConfirm{ mac }` where `mac = HMAC(key = HKDF(...,info:"Portview SAS confirm v2"), "ok")`;
H verifies and, on K mismatches **within the open pairing window**, closes the window with a
user-visible "too many attempts". Keep it scoped to the window (never a global/remote lock). Mark
OPTIONAL — do not let it become the security story; ship core first.

**Security assumption if E is deferred (state plainly):** with the commitment, the only remaining
attack is an online ~1/10⁶ guess per attempt, and core-only v2's bound on the number of attempts is
(a) the pairing-window timeout/concurrency cap (Guardrail C) and (b) **the human stopping after a few
visible "codes didn't match — possible interception" failures**. That is the standard SAS trust model
(the human is the rate-limiter) and is acceptable for attended pairing. Promote E to REQUIRED before
any *unattended/auto-display* pairing mode, which removes the human limiter.

---

## Cryptographic fixes folded in (v1 review)
- **Modular bias** (v1: `% 1_000_000` on 2²⁰ made codes 000000–048575 twice as likely): derive **8
  bytes** then `% 1_000_000` → residual bias < 2⁻⁴⁴, branch-free, no rejection sampling.
- **HKDF API is frozen**: full `HKDF<SHA256>.deriveKey(inputKeyMaterial:salt:info:outputByteCount:)`
  (NOT `HKDF.expand`). `info` = `"Portview SAS v2"` (the version tag — bump to roll the construction).
- The salt/IKM split (cert hash = salt, nonces = IKM) is sound (it's `HMAC(certHash, nonces)`); keep
  it for wire-stability with the KAT.

---

## Files (when implemented) — mirror the named existing patterns, don't invent
- `Sources/PortviewProtocol`:
  - `MessageType` += `sasClientCommit = 20`, `sasHostCommit = 21`, `sasClientReveal = 22`,
    `sasHostReveal = 23` (current max is 19). *(+`sasClientConfirm = 24` only if Guardrail E.)*
  - `Messages/SASClientCommit.swift` + `SASHostCommit.swift` (32-byte field via
    `w.putBytes`/`r.readBytes(32)`), `Messages/SASClientReveal.swift` + `SASHostReveal.swift`
    (16-byte nonce via `putBytes`/`readBytes(16)`). Mirror `CursorPosition.swift`'s `WireMessage`
    shape (messageType + symmetric encode/init). Fixed widths → no length prefix needed.
  - `AnyMessage.swift` (add the cases AND the `messageType` switch arm — both halves) and `Frame.swift`
    (add cases in BOTH `encodeAny` and `decodeBody` — a missing `decodeBody` case throws at runtime).
  - `SASCode.swift` (NEW, pure, TDD focus): `derive(clientNonce:hostNonce:certSHA256:) -> String`
    (CryptoKit HKDF as above) and `commit(nonce:role:certSHA256:) -> Data` (SHA256 of the tagged
    input). No I/O, no logging.
- `Sources/PortviewTransport`: `SASPreamblePinning.swift` (Guardrail A), `QUICParameters
  .clientCapturingCert`, `PortviewConnection.connectCapturingCert`.
- `Sources/PortviewHostCore`: `HostRunner` accept-dispatch (first-message role-lock) + `serveSASPreamble`
  + pairing-window state + `HostRunnerEvent.sasCode(String)`; `SASAttemptLimiter.swift` (NEW, injected
  `now`, mirror the `loadOrCreatePersistent(...,now:)` seam) for Guardrails C/E.
- `apps/PortviewHost`: pairing-mode action + `HostAppModel.displayedSASCode` lifecycle + HUD render.
- `apps/PortviewClient`: `SessionViewModel.beginSASPairing(to:)` / `submitSASCode(_:)` + `sasPairing`
  state + clean preamble teardown and pinned re-dial (mirror `bindConnection`/`unbindConnection` +
  `reconnectLoop` discipline; reset `connectedHostToSave`/`sessionPinHex` like `start`). `ContentView`
  discovered-host tap → numeric 6-digit SAS sheet (replaces the 64-hex alert); thread the captured
  `Data` pin straight to the re-dial (or round-trip-test `hexEncoded`).

## Tests (TDD)
- `SASCode.derive`: determinism; **cert-binding** (different `certSHA256` → different code = MITM-defeat
  invariant); nonce sensitivity; always 6 digits incl. leading zeros; **frozen known-answer vector**
  (fixed `n_c`,`n_h`,`certSHA256` as hex → exact 6-digit output) pinning EVERY ambiguity: IKM order
  `n_c‖n_h`, salt = raw 32 bytes (not hex), `info` exact UTF-8, L=8, big-endian UInt64 of prk8[0..8],
  `% 1_000_000`, `"%06u"`, full `deriveKey` (not `expand`).
- `SASCode.commit`: determinism; the tagged input order (`T‖role‖certSHA256‖nonce`); a reveal verifies
  iff it matches (`commit(n)==received`), and a tampered nonce/role/cert fails.
- **MITM-resistance property test**: assert that a value committed before the peer nonce is known
  cannot be chosen to hit a target code — operationally: `derive` is a deterministic function whose
  output is independent across distinct nonce sets, and `commit` binds the nonce so it can't be
  changed post-hoc (express as: for random committed `n_h'`, P(derive(...,n_h') == target) ≈ 1e-6
  over a sample — sanity bound, not a security proof, but it documents the intent and catches a
  regression that, e.g., drops the nonce from the IKM).
- Message round-trips for tags 20–23 (mirror existing round-trip tests) + the `Frame.decodeBody` arm.
- `SASAttemptLimiter` (injected `now`): sliding-window boundaries (`>` vs `>=` at the edge), lockout
  computed from trip-time `now`, success clears the window, limiter consulted BEFORE deriving/sending.
- **Negative pin test** (Guardrail A): production `QUICParameters.client` verify → `complete(false)`
  on a mismatched cert.
- Two preambles → different host nonces (Guardrail D).
- Optional loopback integration: both sides derive equal code; captured hash == `identity.certificateSHA256()`.

## Re-review checklist before implementation (carry from the v1 review)
1. Confirm the binding argument with the implemented ordering (commit strictly before any reveal,
   per leg; reveal verified against commit; abort on mismatch).
2. Confirm `SASPreamblePinning` is unreachable from any streaming path (grep + negative test).
3. Confirm `serveSASPreamble` constructs no clipboard/injector/capture/file objects and that the
   accept-dispatch locks the connection role on first message.
4. Confirm the pairing window gates BOTH the HUD code and preamble acceptance, and that lockout is
   window-scoped.
5. Confirm no `print`/log of code/nonce/cert-hash; `displayedSASCode` clears on all four hooks.
6. Confirm the KAT is frozen and both endpoints test against it.

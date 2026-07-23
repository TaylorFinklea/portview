# Spec — Client device keypairs + revocable host PairingStore (mutual auth)

> Lead-authored (Fable 5, 2026-07-01) to gate beads `t-store` (screenshare-5yw) and
> `t-authgate` (screenshare-9m2). Anchors the arch-review security decision B
> (decisions.md 2026-07-01) and the unbuilt M6 "device keypairs + revocable PairingStore."
> Follow the SAS pairing arc (design → adversarial review → TDD): decisions.md 2026-06-19/06-20.

## Problem (verified)

Trust is one-directional. `QUICParameters.server` installs only a local identity — no
client-verify block — and `HostRunner.serveSession` builds ClipboardSync / InputInjector /
CaptureEngine / FileReceiver and streams to **any** peer that completes a bare `ClientHello`
(`protocolVersion, deviceID, deviceName, codecs` — `deviceID`/`deviceName` are unauthenticated
strings). The pin is a client-side host-verification secret only; the SAS window is consulted
only on the preamble path, never on the streaming path. So anyone who can reach `host:port`
and speak the protocol controls the Mac. On the intended trusted overlay VPN this is bounded
to the user's own devices; on a shared LAN it is full takeover.

## Goal

The host authenticates each client by a **persistent per-device keypair**, enrolled into a
**revocable, keychain-backed host-side PairingStore** during pairing, and verified on every
streaming handshake **before any scaffolding is built**. Revoking a device makes its next
connection fail closed.

## Design

### 1. Client device identity (iOS)

- A persistent **Curve25519.Signing** keypair (CryptoKit) per install. The **device identity**
  = SHA-256 of the raw public-key representation (32 bytes → a stable id string, hex).
- Persist the private key via the same injectable-store pattern the host already uses:
  define a client-side `ClientIdentityStore` protocol (`read/write` an opaque blob by key)
  mirroring `IdentityRecordStore` (TLSIdentity.swift:215-218); real impl = iOS Keychain
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, mirroring `KeychainIdentityStore`),
  tests inject in-memory. The stored blob is the private key's `rawRepresentation`.
- **Do not** put the private key on the wire; only the public key + signatures travel.
- Rationale for CryptoKit Curve25519 over a client TLS cert: no openssl shell-out (unavailable
  on iOS; the host mints its cert via openssl on macOS), pure/testable signing, and it fits the
  signed-challenge handshake (option B below) without `sec_protocol` client-cert plumbing.

### 2. Host-side PairingStore (bead t-store)

Mirror `IdentityRecordStore` exactly. New `Sources/PortviewTransport/PairingStore.swift`:

- `EnrolledClient: Codable` — `{ id: String (pubkey-SHA256 hex), publicKey: Data (raw),
  deviceName: String, enrolledAt: Date, lastSeen: Date }`.
- `protocol PairingRecordStore { func read() throws -> Data?; func write(_ Data) throws }`
  (one keychain generic-password item holding the Codable `[String: EnrolledClient]` map;
  device-only accessibility; tests inject memory). Distinct keychain `service` from the
  TLS-identity item (see API-Keys convention: app vs CLI use distinct items).
- `actor PairingStore` (async surface — matches the actor direction from bead x-actors) with:
  `enroll(_ EnrolledClient)`, `revoke(id:)`, `isAuthorized(id:) -> Bool`,
  `list() -> [EnrolledClient]`, `touch(id:)` (update lastSeen). All persist through the store.
- **`isAuthorized` MUST fail CLOSED (review must-fix, dos-revocation lens).** Do NOT copy
  `TLSIdentity.loadOrCreatePersistent`'s degrade-to-ephemeral instinct here — that store is
  deliberately fail-OPEN so the host always starts, which is exactly wrong for an authorization
  gate. Any read/decode error → `return false`; an empty/absent map → nobody authorized (not
  "no restrictions yet"). To keep a keychain that locks mid-session from bricking a live host,
  the actor caches the decoded map in memory after the first successful read and authorizes
  from the cache. Ship a test that injects a throwing store and asserts `isAuthorized == false`.
- **t-store scope stops here** (store + CRUD + tests, no handshake wiring).

### 3. Authenticated streaming handshake (bead t-authgate) — signed-challenge (option B)

Chosen over mTLS for testability + incremental fit; mTLS (a `sec_protocol` client-verify block
in `QUICParameters.server` checking the leaf against the store) is noted as a future
defense-in-depth upgrade, not this bead.

Flow, before `serveSession` builds any scaffolding:

1. On a new streaming connection the host sends **`ServerChallenge`** (new tag 30, host→client)
   = a fresh 32-byte CSPRNG `nonce`. (Frame it like any message; add to MessageType/AnyMessage/
   Frame + the golden KAT + EnumTests — the wire-safety gates from waves 1-2.)
2. Client replies **`ClientAuth`** (new tag 31, client→host) = `{ publicKey: Data (raw),
   signature: Data }` where `signature = Sign(clientPrivKey, "Portview client-auth v1" ‖ nonce
   ‖ hostCertSHA256)`. Binding `hostCertSHA256` (the pin the client already holds) into the
   signed payload defeats relay: a MITM presenting its own cert can't get the client to sign
   over the MITM's cert hash for the real host.
3. Host verifies: (a) the signature is valid for `publicKey` over the exact payload it issued;
   (b) `id = SHA256(publicKey)` is `isAuthorized` in the PairingStore. **Both must hold** or the
   host `connection.close()`s and returns — NO ClipboardSync/InputInjector/CaptureEngine/
   FileReceiver constructed (mirror the `serveSASPreamble` fence that builds none of that).
4. Only on success does the loop proceed to the existing `ClientHello`→`StartSession` path.
   `touch(id:)` updates lastSeen.

Ordering vs the existing role-peek: `serveSession` currently peeks the first message to branch
SAS-preamble vs streaming. Keep that; the streaming branch gains the challenge/auth exchange as
its first two steps. The SAS-preamble branch is unchanged except it becomes the **enrollment**
point (§4). Gate the whole thing behind a feature flag / protocol-version bump (see w-version)
so an un-migrated client isn't locked out mid-rollout — default off until the client ships the
keypair, then required.

### 4. Enrollment

- **SAS pairing (preferred, user-attended)**: on a successful SAS code match, the client is
  known-good to the human; the client sends its `publicKey` (piggyback on the existing SAS
  confirm or a small follow-up message) and the host `enroll`s it. This is the clean trust
  root — the user is present and matched a code.
- **QR pairing**: the QR already conveys the pinned host cert. Enrollment on first pinned
  connect is TOFU-on-the-host; to avoid silently trusting whoever connects first, require a
  host-side one-tap "allow this new device (name)" confirm in the menu-bar before `enroll`
  (out of these beads' scope — a UI follow-up bead). Until enrolled, the signed-challenge gate
  fails closed.
- Migration: first rollout enrolls the existing device on its next SAS/confirmed connect.

### 5. Revocation

`revoke(id:)` removes the map entry. The next handshake's `isAuthorized` returns false →
connection closed pre-scaffolding. Host menu-bar UI to list + revoke enrolled devices is a
follow-up bead (references `PairingStore.list()/revoke`).

## Wire additions

`ServerChallenge` (tag 30, host→client, `nonce: Data`), `ClientAuth` (tag 31, client→host,
`publicKey: Data`, `signature: Data`). Each MUST land with a pinned GoldenFrameTests vector and
an EnumTests set entry (wire-safety gates). Reserved-range doc: these are host↔client control —
place per the MessageType range comment. Depends on `w-skip` (done) so an old peer that doesn't
know 30/31 skips rather than wedges during rollout.

## Test plan (TDD)

- **Crypto (pure)**: sign/verify round-trip; verify FAILS for a tampered payload, wrong key,
  or a nonce/host-hash mismatch (replay + relay). Frozen KAT for the signed-payload framing.
- **PairingStore (in-memory)**: enroll→isAuthorized true; non-enrolled false; revoke→false;
  list reflects enroll/revoke; persistence round-trips through an injected store.
- **Auth gate (t-authgate)**: drive `serveSession` (or a factored `authorize` step) with an
  unauthorized/forged `ClientAuth` and assert the connection closes with NO scaffolding
  activated (assert via an injected sink / a `didBuildScaffolding` seam); an enrolled, correctly
  signing client proceeds to `ClientHello`.
- **Enrollment**: a successful SAS match enrolls the client's pubkey (host `isAuthorized` true
  afterward).
- Verify: `swift test --package-path /Users/tfinklea/git/screenshare --filter PairingStore`
  (t-store) and `--filter ClientAuth` (t-authgate). Device follow-up (human-gated): an unpaired
  client is refused on real hardware; a revoked device loses access on its next reconnect.

## Adversarial-review lenses (before/after impl)

Replay (nonce freshness + single-use), relay/MITM (host-cert binding in the signature),
enrollment MITM (SAS is the attended root; QR needs the host confirm), downgrade (can a client
skip ClientAuth or force the flag off? — the host must REQUIRE it once enabled, not infer),
revocation race (revoke mid-session — decide: existing sessions continue, new handshakes fail;
document), key-theft (device-only keychain accessibility; revoke is the recovery).

## Sequencing

`t-store` (store + CRUD, no wiring) → `t-authgate` (challenge/auth + gate + enrollment), which
also depends on `w-skip` (done) for safe rollout. Both are `tier_floor: lead`. The menu-bar
revoke UI and the mTLS upgrade are separate follow-up beads.

## Open review pass (fold before t-authgate implementation)

A 5-lens security review (2026-07-02) confirmed the signed-challenge core (§3) is sound —
the host-cert-hash binding defeats relay, the nonce defeats replay — and the `isAuthorized`
fail-closed rule above was folded in from it. **One load-bearing finding remains for the author
to resolve before `t-authgate` is dispatched: the §4 SAS-enrollment trust root.** A SAS confirm
MAC proves only that a peer completed the commit-reveal preamble; it is computable by any peer
that ran the preamble (all inputs are public/derivable) and carries no host-observable proof that
the *human* approved *that* device. So "enroll on a successful SAS match" lets any LAN peer in the
open pairing window enroll its own key. Resolution direction (pick one, then re-review): (a) drop
the SAS exemption and require the same host-side one-tap "allow this device (name + key
fingerprint)" confirm that §4 already mandates for QR; or (b) bind the enrolled pubkey into the
SAS transcript (cover it in the confirm MAC) so the host rejects a pubkey that didn't participate
in the matched session. Until resolved, `t-authgate` stays `tier_floor: lead` and blocked on this
decision. Full review output: the session's `w9tenxck7` workflow result.

## §4 RESOLVED + full hardening (2026-07-21, adversarial review: GPT-5.6 Sol max + Kimi K3)

Two independent adversarial reviews (Sol at max effort, Kimi K3) CONVERGED: **Option (a) is the
enrollment trust root — SOUND-WITH-FIXES.** Option (b) is confirmed *weaker*, not stronger: the
SAS confirm MAC derives from `clientNonce+hostNonce+certSHA256` (all transcript-public;
SASCode.swift:67-83), so any peer that ran a preamble can produce a valid confirm over *its own*
pubkey with zero human involvement. No MAC over transcript-derived keys can prove human approval
of a specific key; keep (b)-style transcript/key binding only as complementary defense-in-depth,
never as an auto-enroll exemption. **Decision: Option (a).** `t-store` (§2, PairingStore) is
IMPLEMENTED (2026-07-21, fail-closed + id==SHA256(pubkey) derived). The must-fixes below are
mandatory before `t-authgate` ships — without fixes 1–2 the recommendation is BROKEN (blind-tap
TOFU), per both reviewers.

**Enrollment must-fixes (fold into §4):**

1. **Enroll at the signed-challenge gate, not from preamble data.** Unknown pubkey + VALID
   signature over the fresh nonce on the *pinned re-dial* + open pairing window → raise the
   prompt → Allow → `enroll` → proceed. This makes displayed fingerprint == enrolled key == the
   key that just proved possession on a pinned channel, closing the display→enroll binding gap by
   construction (both reviewers). Ordering trap: the client re-dials pinned immediately on match
   (SASClientCoordinator.swift:138), so its first `ClientAuth` arrives UNENROLLED — the gate must
   treat "unknown key, valid sig, window open" as prompt-pending, not instant-close. Enroll the
   exact pubkey byte-snapshot captured at prompt-render; never re-read a mutable "pending key" at
   tap time.
2. **Client displays its own key fingerprint during pairing; host prompt shows the same
   host-computed fingerprint** for the human to COMPARE (≥ 80 displayed bits, e.g. 8 bytes hex or
   a word encoding). Without an independently-shown reference the tap is explicit TOFU.
3. **The host approval tap must require genuine LOCAL presence** (Sol, critical): Portview injects
   CGEvents globally (InputInjector.swift) and input dispatches even before `ClientHello`
   (HostRunner.swift:640-641), so an attacker with temporary/compromised access could remotely
   click "Allow." Require `LAContext`/Touch ID, OR atomically suspend all remote input + discard
   queued injected events + reject Portview-originated input until the prompt is dismissed.
   Disconnect existing legacy sessions before enabling enrollment.
4. **`deviceName` is attacker-controlled** (ClientHello.swift:6-18): label it "a device calling
   itself X", sanitize control/bidi chars, truncate, and NEVER use it for identity — the
   fingerprint is the sole anchor.
5. **One outstanding enrollment request per user-opened window** (or an immutable attempt UUID on
   every event). The request captures `{attemptID, exact publicKey, host-computed fingerprint,
   claimedName, expiry, session binding}`; Allow atomically consumes THAT exact request; Deny/
   timeout/close invalidates it and blocks that source for the window (reuse
   `SASPairingControl.sourceKey`).
6. **Pin the first in-flight preamble's HUD code** until it resolves — the single-slot `.sasCode`
   overwrite (HostRunner.swift:711) is a pre-existing pairing-DoS that compounds prompt confusion.

**§3 handshake corrections (fold into §3 + Wire additions):**

- **TAGS ARE WRONG in the original spec.** Tag 30 is already `requestKeyframe`, 29 is
  `clientFeedback` (MessageType.swift:39-40). Allocate **`ServerChallenge` = tag 31**,
  **`ClientAuth` = tag 32**. Each lands with a golden KAT + EnumTests entry (wire-safety gates).
- **Message order:** `ClientHello → ServerChallenge → ClientAuth → ServerHello → StartSession`
  (the host needs the first client message to distinguish streaming vs SAS; the client already
  sends ClientHello first — SessionViewModel.swift:505-515). First frame must be exactly
  `SASClientCommit` or `ClientHello`; anything else closes. No privileged resources built before a
  successful `ClientAuth`.
- **Frozen signed bytes:** `UTF8("Portview client-auth v1") ‖ nonce[32] ‖ hostCertDER_SHA256[32]`
  — no hex, no optional/variable-length fields. `ServerChallenge` = the 32-byte nonce ONLY (a
  server-supplied cert hash would let a relay obtain a signature over the real host's hash);
  client signs the pin it already holds. New decoders reject trailing bytes. Fresh CSPRNG nonce
  per connection, one auth response under a short deadline, close on timeout/malformed/unexpected/
  verify-fail. **Remove the empty-array `hostCertSHA256` fallback (HostRunner.swift:149)** — auth
  binding must fail closed if the 32-byte hash is unavailable.

**Rollout gate (never wire-negotiated):** `ProtocolVersion.negotiate` takes the LOWER version, so
"authenticate when version ≥ authVersion" is bypassable by advertising v1. Ship a HOST-LOCAL
policy: `.required` (default, fail-closed) vs `.legacyBootstrap(expiresAt:)` (explicit, warned,
time-bounded; new-capability clients still authenticate; closing it disconnects legacy sessions).
Version sequencing interacts with the dormant lanes lever (memory `lanes-dormant-lever`): because
`current==1` and dormant `laneVersion==2` would activate lanes if `current` bumped, the clean
order is `mutualAuthVersion=2`, MOVE dormant `laneVersion→3`, set `current=2` for mutual auth,
activate lanes later at v3 after their A/B. Safe one-directional auto-promotion `bootstrap→required`
once the PairingStore is non-empty (only auth-capable clients can have enrolled). **This
version/lanes interaction is a user-facing sequencing decision — confirm before touching
`ProtocolVersion`.**

**Revocation = emergency capability withdrawal (both reviewers): revoke MUST terminate live
sessions**, not just future handshakes — a screen-control tool leaves keyboard/mouse/clipboard/
file access running otherwise, and active traffic prevents the QUIC idle timeout from bounding it.
Implementation properties: keep both per-connection `SessionID` and authenticated `ClientKeyID`
(thread the key id into `control.register`, HostRunner.swift:614); index `byClient`; serialize
admission + revocation through one shared authority (avoid multiple PairingStore instances with
stale caches); use an enrollment generation/epoch so a delayed teardown can't kill a later
re-enrollment; make authorization-check + session registration atomic (or register-then-recheck
before privileged setup); mark the session capability invalid BEFORE closing transport
(InboundBuffer.finish drains queued messages — buffered input could execute post-revoke); don't
reuse `disconnectAll()` (it sends `bye` async before closing) as the security primitive — revoke
invalidates synchronously and closes immediately. A separate "deny future reconnects" op may have
deferred semantics; Revoke may not.

**Lane token hygiene: DONE** (2026-07-21, commit). Constant-time compare + never-log landed;
both reviewers confirmed it is defense-in-depth, NOT load-bearing (reachable only by the pinned
tunnel peer already holding the 32-byte token; 8-attempt cap).

**Re-sequenced beads:** `t-store` DONE. `t-authgate` (now materially larger than the original
spec) splits into: (i) wire additions `ServerChallenge`/`ClientAuth` tags 31/32 + KATs + client
Curve25519 keypair/ClientIdentityStore (§1) + signed-challenge crypto (pure, TDD); (ii) the
`serveSession` auth gate + host-local rollout policy; (iii) the enrollment ceremony (local-presence
prompt + dual-fingerprint compare + per-window request) — has real iOS/macOS UI + a user product
decision; (iv) revoke-kills-live-sessions + the ClientKeyID/epoch session-registry changes + menu-
bar revoke UI. All `tier_floor: lead`.

## han.1 implementation addendum (2026-07-22)

The §3 gate + host-local rollout policy are IMPLEMENTED (`serveAuthGate`/`MutualAuthPolicy`,
Kimi K3-reviewed SHIP-WITH-FIXES, folded). One §4-RESOLVED clause is deliberately re-sequenced:
**"closing legacy bootstrap disconnects legacy sessions" is NOT in han.1 — bead (iv) explicitly
owns it** (the session registry must record each session's auth class, and any effectiveMode
transition to `.required` — first-enrollment auto-promotion or expiry — synchronously invalidates
and closes legacy-admitted sessions, same machinery as revoke-kills-live). SEQUENCING CONSTRAINT:
bead (iv)'s eviction must land BEFORE or WITH bead (iii) — promotion is unreachable until
enrollment exists, which is why han.1 could ship without it. Both call sites run
`.legacyBootstrap(expiresAt: .distantFuture)` until (iii); the expiry is a user decision there.

## han.1 EXPAND addendum (2026-07-22, dual review Kimi K3 SHIP-WITH-FIXES + Sol RETURN)

Sol's RETURN was answered by EXPANDING han.1 rather than deferring (user decision). Landed here:
- **Durable/monotonic promotion**: `PairingStore.migrationComplete` (set on first enroll, never
  cleared) + `enrollmentSnapshot()` tri-state. Revoking the last device or a host restart can no
  longer reopen bootstrap; an unreadable store fails closed to `.required`.
- **Legacy eviction mechanism**: `HostControl.SessionAuthClass` tagging + `evictLegacyAdmitted()`
  (synchronous close, no `bye`); a lazy sweep fires on any `.required`-mode connection.
- **Single-read gate** (no per-message deadline reset → no slot-starvation).

Superseded the earlier han.1 addendum's "eviction is entirely han.4" claim. What REMAINS deferred:
han.4 owns the fine-grained in-flight admission TOCTOU (generation/epoch-bound admission +
register-then-recheck) and the cross-process app/CLI single-authority; han.3 owns the EAGER
evict-at-enroll hook and the `.distantFuture` migration-window decision. han.4 no longer strictly
blocks han.3 (durable promotion + eviction mechanism already shipped).

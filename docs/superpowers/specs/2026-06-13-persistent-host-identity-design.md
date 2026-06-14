# Persistent host identity + stable port

**Date:** 2026-06-13
**Status:** Design — approved (Approach A: persist PKCS#12 blob in Keychain)
**Scope:** host-only (PortviewTransport + PortviewHostCore); no client changes.

## Problem

Saved pairings break on every host restart. Two host-side values that the client
pins/targets are regenerated each launch:

1. **TLS pin floats.** `TLSIdentity.makeEphemeralSelfSigned` (`Sources/PortviewTransport/TLSIdentity.swift`)
   mints a fresh self-signed RSA cert every launch — and with only `-days 2` validity.
   `certificateSHA256()` (the pin baked into the pairing QR and stored in `SavedHost.pinHex`)
   therefore changes each restart, so the client's pin-verify block
   (`CertificatePinning.install`) rejects the reconnect.
2. **Port floats.** `PortviewListener` calls `NWListener(using:)` with no fixed port
   (`Sources/PortviewTransport/PortholeConnection.swift`), so the OS assigns an ephemeral UDP
   port each launch. `SavedHostsStore.remember` keys saved Macs by `host+port` and reconnects
   to the saved literal `host:port`, so a new port misses even if the pin were stable.

Both the CLI (`Sources/portview-host/PortviewHostApp.swift`) and the app
(`apps/PortviewHost/Sources/HostAppModel.swift`) reach identity+listener through
`HostRunner.run` (`Sources/PortviewHostCore/HostRunner.swift`), which mints the identity and
binds the listener internally. Fixing it in `HostRunner` fixes both entry points.

## Goal

A saved pairing reconnects after a host restart (same machine, same LAN/IP): the **pin** and
the **advertised port** are stable across restarts. The supported path is the signed
`PortviewHost.app`; the unsigned dev CLI degrades gracefully to today's ephemeral behavior.

## Non-goals (noted follow-ups, not built here)

- **IP stability.** `SavedHost.host` is a LAN IPv4 from `NetworkInterface.primaryIPv4()`; a DHCP
  change still breaks reconnect. Bonjour rediscovery or a stable Tailscale IP covers this. Add a
  roadmap follow-up; do not solve here.
- **Reset / rotate UI.** A "regenerate identity / forget pairings" affordance in the app. Deferred.
- **Replacing the openssl shell-out** with a native `SecKey`/`SecCertificate` cert generator
  (the long-standing aspiration in the `TLSIdentity` doc comment). Out of scope; we persist the
  existing openssl-minted blob unchanged.

## Approach (A — persist the PKCS#12 blob)

Persist a single Keychain generic-password item containing the opaque `.p12` blob **and** the
chosen port, as one encoded record. On launch, read it back, re-import the identity, and request
the saved port. This reuses the entire tested mint path (openssl → `SecPKCS12Import`); the only new
code is store/load + a one-line listener port param + `HostRunner` wiring.

Rejected: storing a first-class `kSecClassIdentity` (Approach B) — `SecPKCS12Import` already
touches the keychain, identity-item ACLs are brittle for the unsigned `swift run` CLI, and
querying identities by label is fiddlier, for no benefit at this scope.

## Components & changes

### 1. `TLSIdentity` persistence (`Sources/PortviewTransport/TLSIdentity.swift`, `#if os(macOS)`)

Add a persistent load-or-create entry point alongside the existing `makeEphemeralSelfSigned` /
`importPKCS12`. Mirror the existing openssl/import idioms in that file — do not introduce a new
crypto path.

- **`loadOrCreatePersistent(service: String, commonName: String = "Portview Host") -> PersistentIdentity`**
  where `PersistentIdentity` carries the `TLSIdentity` plus an optional persisted `port: UInt16?`.
  Behavior:
  1. Read the Keychain record for `service`. If present: decode `{ p12: Data, port: UInt16 }`,
     `importPKCS12`, and validate the leaf cert is **not expired and has comfortable validity
     remaining** (re-mint threshold: regenerate if < ~30 days left, so a long-lived cert never
     silently expires mid-use). If valid → return identity + persisted port.
  2. Otherwise mint fresh via the existing openssl path with **validity bumped from `-days 2` to
     a long horizon (`-days 3650`)**, store `{ p12, port: 0 }`, return identity + `port == nil`.
     Port `0` is the "not-yet-bound" sentinel (valid ports are 1–65535): `loadOrCreatePersistent`
     maps a stored `0` to a returned `nil`, and `persistPort` is only ever called with the real
     bound port (≥1). The identity is stored immediately on mint (before the port is known) so it
     survives even if a later step fails.
  3. **Any Keychain error (read or write) → fall back to a fresh ephemeral identity** (today's
     behavior) and return `port == nil`. Persistence is best-effort; the host must always start.
- **`persistPort(_ port: UInt16, service: String)`** — update the stored record's port after the
  listener binds (only meaningful when a record exists; best-effort, swallow Keychain errors).
- Internal Keychain helpers (`SecItemCopyMatching` / `SecItemAdd` / `SecItemUpdate` /
  `SecItemDelete`) wrapped in a small private type. Item attributes: `kSecClassGenericPassword`,
  `kSecAttrService = service`, `kSecAttrAccount = "identity"`,
  `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. File-based login
  keychain (default; no `kSecUseDataProtectionKeychain`) so the signed app reads its own item
  prompt-free across launches.
- Cert-expiry check reads the leaf `SecCertificate` validity (e.g. via `SecCertificateCopyValues`
  with `kSecOIDX509V1ValidityNotAfter`); confirm the exact key against the macOS 26 SDK before
  coding — do not prescribe from memory.
- Record encoding: a small `Codable` struct (base64 p12 + `UInt16` port) is sufficient; keep it
  private to `TLSIdentity`.

The passphrase stays the existing constant — the blob's protection is the Keychain item's access
control, not the p12 passphrase.

### 2. `PortviewListener` preferred port (`Sources/PortviewTransport/PortholeConnection.swift`)

- Add an optional `port: UInt16?` to the `quicIdentity:` (and, for symmetry, `identity:`) inits,
  threaded to the private designated init. When non-nil, construct `NWListener(using:on:)` with
  that `NWEndpoint.Port`; when nil, keep the current `NWListener(using:)` (OS-assigned).
- `start()` is unchanged: it already returns the **actual** bound port.
- No change to the connection-accept/double-delivery handling.

### 3. `HostRunner` wiring (`Sources/PortviewHostCore/HostRunner.swift`)

- Replace `TLSIdentity.makeEphemeralSelfSigned(commonName:)` with
  `TLSIdentity.loadOrCreatePersistent(service:)`. Use a fixed service constant, e.g.
  `"dev.finklea.portview.host.identity"`.
- Construct `PortviewListener(quicIdentity:serviceName:port:)` passing the persisted port (nil on
  first run / ephemeral fallback).
- After `listener.start()` returns the bound port, if it differs from the persisted port (first
  run, or the preferred port was taken and the OS reassigned), call `persistPort(_:service:)` so
  the next launch requests the now-known port.
- Bind-failure resilience: if `PortviewListener(... port: X)` / `start()` throws because the
  preferred port is unavailable, retry once with `port: nil` (ephemeral) and persist the new port.
  Keep this localized; do not change the outer error handling for capture/TCC failures.
- `pinHex` derivation and the `HostReadyDetails` / `PairingPayload` construction are unchanged —
  they now just reflect a stable pin + stable port.

## Data flow (after change)

```
HostRunner.run
  └─ TLSIdentity.loadOrCreatePersistent(service)         → (identity stablePin, port?)
  └─ PortviewListener(quicIdentity: identity, port:)      → bind preferred (or ephemeral)
  └─ listener.start()                                     → actualPort
  └─ if actualPort != persisted: persistPort(actualPort)
  └─ PairingPayload(host: ip, port: actualPort, pinHex)   → QR / saved by client
                                                            (pin + port now survive restart)
```

## Error handling

- Keychain unavailable / access denied (e.g. unsigned CLI after a rebuild) → ephemeral identity,
  ephemeral port; host starts normally. Logged via an existing `HostRunnerEvent.message`.
- Stored cert expired or near-expiry → transparent re-mint (new pin); the user re-pairs once.
  Acceptable and rare given the 10-year horizon + 30-day re-mint threshold.
- Preferred port taken → fall back to ephemeral, persist the new port; one missed reconnect, then
  stable again.

## Testing (`Tests/PortviewTransportTests`)

Spec-derived invariants (specify exactly):

1. **Round-trip stability** — `loadOrCreatePersistent(service: <unique>)` twice with the same
   service yields an **identical `certificateSHA256()`** (the pin survives). Use a unique throwaway
   service per test; `defer` a `SecItemDelete` cleanup. Serialize keychain-touching tests if needed
   (mirror the existing `TLSIdentity.importLock` precedent).
2. **Port persistence** — after `persistPort(P, service:)`, a subsequent `loadOrCreatePersistent`
   returns `port == P`.
3. **Expiry re-mint** — a record whose cert is expired (or below threshold) causes
   `loadOrCreatePersistent` to return a **different** pin (regenerated). (Construct via a short-lived
   mint helper; confirm the validity-read path.)
4. **Keychain-failure fallback** — when the store path fails, `loadOrCreatePersistent` still returns
   a usable identity with `port == nil` (no throw).
5. **Listener preferred port** — `PortviewListener(quicIdentity:port: P)` then `start()` reports a
   bound port equal to `P` (when free).
6. **No regression** — existing `QUICBidirectionalTests` round-trip and the full suite stay green.

## Acceptance

- `swift test --package-path .` green (existing 82 + new persistence/port tests).
- `swift build --product portview-host` succeeds.
- `xcodebuild build -project apps/PortviewHost/PortviewHost.xcodeproj -scheme PortviewHost
  -destination 'platform=macOS'` → BUILD SUCCEEDED.
- Manual (human, on-device): launch `PortviewHost.app`, pair from the client, **restart the app**,
  reconnect from the client's Saved Macs list without rescanning — succeeds (same pin + port).

## Commit shape

One feature commit for the implementation + tests; doc/handoff updates folded in or in a trailing
`docs:` commit per repo convention.

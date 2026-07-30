# Security Policy

Portview is pre-release, open-source software (Apache-2.0). This document describes the
trust model, which versions receive fixes, and how to report a vulnerability.

## Trust model

Portview streams your Mac's screen and accepts trackpad/keyboard input from an iPhone over
a direct, encrypted connection — there is no Portview server in between.

- **Network scope.** Portview targets a **local LAN**, or a private overlay you already
  control — **Tailscale** or **WireGuard**. It is not designed to be exposed on the open
  internet, and nothing about the protocol assumes a hostile public network path.
- **Transport.** The connection is **QUIC with TLS**. The host mints its own TLS identity
  on first run and persists it in the Keychain; there is no external CA.
- **Host identity — trust-on-first-use (TOFU).** The client pins the host's certificate by
  its SHA-256 fingerprint. The first connection is trusted on sight, exactly like an SSH
  host key: pair over **QR code** (the fingerprint travels in the QR payload, so there's
  nothing to verify by eye) or via the **6-digit SAS (short-authentication-string) code**,
  which uses a commit-then-reveal handshake so an active on-path attacker can't grind the
  code offline before the user compares it. Every connection after pairing is verified
  against the pinned fingerprint; a changed fingerprint is treated as a possible
  interception, not silently re-trusted.
- **Client identity — mutual authentication is required.** Every client mints a persistent
  per-device **Curve25519 keypair** (private key in the iOS Keychain, never on the wire)
  and must answer a fresh challenge with a signature that also binds the host's certificate
  hash, so a response can't be relayed to a different host. The host serves **only enrolled
  devices**; there is no anonymous or legacy admission path.
- **Enrollment is an attended ceremony.** A new device can enroll only while the pairing
  window is explicitly open on the Mac, and only after the owner compares the device's key
  fingerprint (shown on both screens) and approves with **Touch ID / device-owner
  authentication**. Device names offered by a client are sanitized and never used as
  identity.
- **Revocation kills live sessions.** Revoking a device (Touch ID-gated) terminates its
  active sessions immediately — screen, input, clipboard, and file transfer all stop — and
  its key can only return through the enrollment ceremony. Revoking the last device leaves
  the host serving no one until an in-person re-pair; it never falls back to open
  admission.
- **Recovery is attended, never remote.** If the pairing store becomes unreadable, the
  host fails **closed** (nobody connects). The menu bar carries a break-glass **"Reset
  pairing…"** — Touch ID-gated; it forgets every device, discards pending revocations, and
  quits — after which each device must pair again in person. There is no remote or
  unauthenticated recovery path.
- **Host-side input gating.** The host — not just the client UI — refuses to inject input
  while the Mac's screen is locked, regardless of what a connected client sends.
- **Optional re-wake uses your iCloud.** The reconnect-nudge feature routes a small host
  beacon (host name and endpoint hints — never screen contents) through **your own iCloud
  account's** CloudKit database and Apple push notifications. No Portview-operated server
  is involved, but Apple's cloud is on the path for that one feature. It fails soft and is
  never required for pairing or streaming.

## Known limitations

Stated here so you don't have to discover them:

- **A paired device currently gets every capability** — screen, input, two-way clipboard
  sync, system audio, and file transfer. Per-capability opt-in (clipboard/files off by
  default) is planned but not yet shipped. Pair only devices you fully trust.
- **Revoke can strand one key or mouse button** if it lands exactly between a press and its
  release; the stuck input clears on the next local key press or click. A release pass on
  revoke is planned.
- **Two host processes don't share revocations live.** If you run the GUI app and the
  `portview-host` CLI at once, a device revoked in one keeps its access in the other until
  that process restarts. Run one host at a time.

If you're evaluating Portview for your own use: run it on a network you control, and don't
expose the host's port to the open internet (no port forwarding).

## Supported versions

Portview is pre-release. There are no tagged releases yet — security fixes land on `main`
only. Once tagged releases begin, this section will be updated with a supported-versions
table.

## Reporting a vulnerability

Please report security issues privately using **GitHub's private vulnerability reporting**
(Security Advisories) on this repository:

<https://github.com/TaylorFinklea/portview/security/advisories/new>

Please don't open a public issue for a suspected vulnerability. Include enough detail to
reproduce the issue (affected component, network conditions, steps). We'll acknowledge
reports and follow up as the project's security process matures.

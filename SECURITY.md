# Security Policy

Portview is pre-release, open-source software (Apache-2.0). This document describes the
trust model, which versions receive fixes, and how to report a vulnerability.

## Trust model

Portview streams your Mac's screen and accepts trackpad/keyboard input from an iPhone over
a direct, encrypted connection — there is no server in between.

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
- **Host-side input gating.** The host — not just the client UI — refuses to inject input
  while the Mac's screen is locked, regardless of what a connected client sends.
- **Known gap: no mutual (client) authentication.** The host currently authenticates
  itself to the client (via the pinned TLS certificate), but **does not yet authenticate
  the client** — any peer that completes the handshake and knows/guesses how to reach
  `host:port` is served. On a shared or untrusted LAN this is a real exposure, not just a
  theoretical one. Revocable per-device client keypairs + a host-side pairing store are
  designed (see `docs/superpowers/specs/2026-07-01-revocable-pairing-mutual-auth.md`) but
  **not yet implemented**; this work is intentionally tracked as its own dedicated security
  pass rather than folded into routine feature work. Until it lands, treat Portview as
  suitable for networks you already trust (your own LAN, your own Tailscale/WireGuard
  tailnet) — not for shared or adversarial networks.

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

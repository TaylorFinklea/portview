# Roadmap

> Durable goals and milestones. Updated when scope changes, not every session.

## Vision

Porthole — open-source, native-feeling iPhone→Mac screen sharing & control (own Mac host agent: ScreenCaptureKit + VideoToolbox HEVC over QUIC; iPhone is pure viewer/controller). Replaces laggy VNC. Apache-2.0. macOS 26 / iOS 26, Apple Silicon.

Full design: `docs/superpowers/specs/2026-06-02-porthole-design.md`.

## Now / Next / Later

### Now
- [x] M0 walking skeleton — protocol + transport + media + host exe + iOS client app, all compiling; core pipeline POC color-verified by tests. **Awaiting first run on real hardware** (Screen-Recording grant + iPhone) to confirm a live picture.

### Next
- [ ] M1 — trackpad input (CGEvent) + on-screen keyboard + Bonjour discovery + QR pairing/pinned-cert + saved-Macs list.

### Later
- [ ] M2 clipboard · M3 multi-monitor · M4 audio · M5 file transfer · M6 adaptive quality + reconnect/push-rewake + polish.

## Milestones

### M0: Walking skeleton
- [x] `PortholeProtocol`: lane defs, message types, binary framing, handshake state machine, version negotiation (pure Swift, unit-tested) — 31 tests green
- [x] `PortholeTransport`: connection/listener wrapper over Network.framework — TLS-over-TCP for the POC (QUIC groundwork proven via one-way loopback spike; see decisions.md), cert pinning, handshake + VideoFrame over a real connection. 36 tests green.
- [x] `PortholeMedia`: VideoToolbox HEVC encode + decode (round-trip recovers color); HEVC sample serialization; **full encode→pinned-TLS→decode pipeline POC, color-verified, autonomous**.
- [x] Host: `porthole-host` exe — SCStream capture → VideoEncoder → serialize → serve. Compiles; runs with a Screen-Recording grant.
- [x] Client: iOS app — receive → deserialize → AVSampleBufferDisplayLayer render. Compiles for iOS 26 sim (BUILD SUCCEEDED). *(CAMetalLayer is a later latency optimization.)*
- [x] Package macOS host (SwiftPM exe) + iOS client app (xcodegen). Run guide: `apps/README.md`. *(Running on a real iPhone needs Xcode + your signing team.)*
- [ ] Latency harness; confirm <50 ms motion-to-photon
- [x] Resolve open Qs: iOS 26 QUIC datagrams (supported; deferred) ✓; HEVC encode works on macOS 26 ✓ (EnableLowLatencyRateControl accepted)

### M1: Control + connect
- [ ] InputInjector (CGEvent global coords) + input lane; trackpad gesture→message mapping
- [ ] On-screen keyboard; Secure Input detection + banner
- [ ] Bonjour advertise/browse `_porthole._udp`; manual add (Tailscale host)
- [ ] QR pairing + device keypairs + pinned server identity; revocable PairingStore
- [ ] Saved-Macs list; TCC onboarding (Screen Recording + Accessibility)

### M2: Clipboard sync (text, both ways)
### M3: Multi-monitor (pick/switch display)
### M4: Audio (Core Audio process tap → encode → A/V-synced playback)
### M5: File transfer (files lane)
### M6: Polish (adaptive bitrate/fps, reconnect + APNs re-wake, settings, quality HUD)

## Backlog

> (none yet — milestones above are the active plan)

## Constraints

- Apple Silicon only; macOS 26+ / iOS 26+. Swift 6.2 / Xcode 26.
- Mac must be logged in (no pre-login capture / no remote-unlock — hard public-API limit).
- iOS session is foreground-only (background suspends + drops connection; re-wake via push).
- No servers we host; remote is the user's own overlay VPN.
- Permissive license → clean-room only (no GPL refs like Lumen/Moonlight).

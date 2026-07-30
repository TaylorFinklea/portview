# 🪟 Portview

**Native iPhone → Mac screen sharing and control that actually feels native.**

Mac-to-Mac screen sharing feels instant because, when both ends are Apple, macOS uses a private, hardware-accelerated video path. From an iPhone you're stuck with VNC, which feels laggy. Portview closes that gap with a fully open-source stack: a tiny Mac helper captures the screen with **ScreenCaptureKit**, hardware-encodes **HEVC** with **VideoToolbox**, and streams it over an encrypted **QUIC** connection to a native iPhone app that hardware-decodes, renders through **Metal**, and sends back trackpad-style input.

No reverse-engineering of Apple's proprietary protocol. No servers. No VNC.

- **Direct on the LAN**, or remote over your own Tailscale/WireGuard — nothing for us to host.
- **Paired devices only.** Mutual authentication: the client pins the host's certificate, and the host serves only devices enrolled through an attended, Touch ID-gated pairing ceremony. Revocation kills live sessions. See [`SECURITY.md`](SECURITY.md).
- **iPhone is a pure viewer/controller**, which sidesteps every iOS screen-capture restriction.
- **Apple Silicon, macOS 26+ / iOS 26+.** Swift 6, the newest capture/encode/QUIC APIs.

> Status: **approaching v1.0.** The Mac host ships as a notarized direct download; the iPhone app is built from source for now. See [`docs/superpowers/specs/2026-06-02-portview-design.md`](docs/superpowers/specs/2026-06-02-portview-design.md) for the full design.

## Architecture

```
🖥️ Mac host (menu-bar app)               📱 iPhone client (SwiftUI)
   ScreenCaptureKit  ─ capture + audio      NetworkConnection ─ QUIC
   VideoToolbox      ─ HEVC encode   ⇄      VideoToolbox      ─ decode
   CGEvent           ─ input inject  QUIC   CAMetalLayer      ─ render
   Keychain          ─ pairing store (TLS)  gestures          ─ trackpad input
```

One QUIC connection carries video, audio, input, control, clipboard, file, and stats traffic; latency-critical input is tiny and prioritized so a file transfer can never stall your cursor. (Per-lane QUIC streams are implemented but deliberately dormant pending an on-device A/B.)

## Install

**Mac host** — download `PortviewHost.zip` from the latest GitHub release (Developer ID-signed, notarized, stapled — no Gatekeeper warning), unzip, and drag `PortviewHost.app` into `/Applications`. First run walks you through the Screen Recording and Accessibility permissions.

**iPhone client** — build from source with your own Apple ID for now (see [`apps/README.md`](apps/README.md)); TestFlight distribution is planned.

## Roadmap

| Milestone | What |
|-----------|------|
| **M0** | Walking skeleton: protocol package + Mac→iPhone live video |
| **M1** | Trackpad control, keyboard, Bonjour discovery, QR pairing |
| **M2** | Clipboard sync · **M3** Multi-monitor · **M4** Audio · **M5** File transfer |
| **Security** | Mutual auth: per-device keypairs, attended enrollment, live-session revoke, break-glass reset |
| **M6** | Adaptive quality, reconnect + iCloud re-wake, polish |

## License

[Apache-2.0](LICENSE) © 2026 Taylor Finklea

# 🪟 Portview

**Native iPhone → Mac screen sharing and control that actually feels native.**

Mac-to-Mac screen sharing feels instant because, when both ends are Apple, macOS uses a private, hardware-accelerated video path. From an iPhone you're stuck with VNC, which feels laggy. Portview closes that gap with a fully open-source stack: a tiny Mac helper captures the screen with **ScreenCaptureKit**, hardware-encodes **HEVC** with **VideoToolbox**, and streams it over an encrypted **QUIC** connection to a native iPhone app that hardware-decodes, renders through **Metal**, and sends back trackpad-style input.

No reverse-engineering of Apple's proprietary protocol. No servers. No VNC.

- **Direct on the LAN**, or remote over your own Tailscale/WireGuard — nothing for us to host.
- **iPhone is a pure viewer/controller**, which sidesteps every iOS screen-capture restriction.
- **Apple Silicon, macOS 26+ / iOS 26+.** Swift 6, the newest capture/encode/QUIC APIs.

> Status: **early development.** See [`docs/superpowers/specs/2026-06-02-portview-design.md`](docs/superpowers/specs/2026-06-02-portview-design.md) for the full design, and [`.docs/ai/roadmap.md`](.docs/ai/roadmap.md) for the milestone roadmap.

## Architecture

```
🖥️ Mac host (menu-bar agent)            📱 iPhone client (SwiftUI)
   ScreenCaptureKit  ─ capture             NetworkConnection ─ QUIC
   VideoToolbox      ─ HEVC encode   ⇄     VideoToolbox      ─ decode
   CGEvent           ─ input inject  QUIC  CAMetalLayer      ─ render
   Core Audio tap    ─ audio        (TLS)  gestures          ─ trackpad input
```

One QUIC connection carries six logical lanes: **video** and **audio** (push, drop-stale), **input** and **control** and **clipboard** and **files** (reliable). Input is tiny and prioritized so a file transfer can never stall your cursor.

## Roadmap

| Milestone | What |
|-----------|------|
| **M0** | Walking skeleton: protocol package + Mac→iPhone live video |
| **M1** | Trackpad control, keyboard, Bonjour discovery, QR pairing |
| **M2** | Clipboard sync · **M3** Multi-monitor · **M4** Audio · **M5** File transfer |
| **M6** | Adaptive quality, reconnect, polish |

## License

[Apache-2.0](LICENSE) © 2026 Taylor Finklea

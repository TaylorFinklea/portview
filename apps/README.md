# Running Portview (POC)

Portview is two apps over a shared, tested core (`PortviewProtocol`, `PortviewTransport`, `PortviewMedia`):

- **`portview-host`** — a macOS `swift run` executable that captures the screen, hardware-HEVC-encodes it, and serves it.
- **iOS client** (`apps/PortviewClient`) — a SwiftUI app that connects, decodes, and displays the Mac's screen.

> **POC status.** The core pipeline (capture → HEVC encode → certificate-pinned TLS → HEVC decode → display) is wired end to end. The transport is **TLS-over-TCP** for the POC (QUIC is the production target; see `.docs/ai/decisions.md`). You connect by entering the host's **IP + port + pin** — Bonjour discovery and QR pairing are the next milestone. **Viewing only so far**; trackpad control is the next milestone after that.

## 1. Run the Mac host

```bash
swift run portview-host
```

On first run macOS blocks screen capture until you grant permission: **System Settings ▸ Privacy & Security ▸ Screen Recording**, enable your terminal (or the host), then run again. The host prints something like:

```
🪟  Portview host ready
 Port:  54321
 Pin:   3a7f…  (64 hex chars)
```

Note the **port** and **pin**, plus your Mac's **LAN IP** (System Settings ▸ Wi-Fi ▸ Details — e.g. `10.0.0.5`). The phone must be on the same Wi-Fi (or reach the Mac over your Tailscale).

## 2. Run the iOS client

```bash
cd apps/PortviewClient
xcodegen generate          # regenerates PortviewClient.xcodeproj from project.yml
open PortviewClient.xcodeproj
```

In Xcode: pick your iPhone as the destination (set your Signing Team on the `PortviewClient` target for a real device), then Run. In the app, enter the Mac's **IP**, **port**, and **pin**, and tap **Connect** — the Mac's screen appears.

To try it in the **iOS Simulator** (host and client on the same Mac), use `127.0.0.1` as the IP.

## What works / what's next

- ✅ Live screen view, host → iPhone, HEVC over certificate-pinned TLS.
- ⏭️ Next: trackpad control (input lane), Bonjour discovery + QR pairing, then audio · clipboard · file transfer · multi-monitor · QUIC transport · Metal renderer. See `.docs/ai/roadmap.md`.

# Running Portview (POC)

Portview is two apps over a shared, tested core (`PortviewProtocol`, `PortviewTransport`, `PortviewMedia`, `PortviewHostCore`):

- **Mac host** (`apps/PortviewHost`) — a signed macOS app that captures the screen, hardware-HEVC-encodes it, and serves it under Portview's own Screen Recording identity.
- **iOS client** (`apps/PortviewClient`) — a SwiftUI app that connects, decodes, and displays the Mac's screen.

> **POC status.** The core pipeline (capture → HEVC encode → certificate-pinned QUIC → HEVC decode → display/control) is wired end to end. Bonjour discovery, QR pairing, clipboard, audio, file transfer, multi-monitor, Metal rendering, and the diagnostics HUD are implemented. The current manual test focus is device-side motion/quality tuning.

## Prerequisites

- **Xcode 26** on **macOS 26**, **Apple Silicon**. The Swift 6.2 toolchain comes with Xcode — no separate install.
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen), used to generate both apps' `.xcodeproj` from `project.yml`:

  ```bash
  brew install xcodegen
  ```

## 1. Run the Mac host

```bash
cd apps/PortviewHost
xcodegen generate
open PortviewHost.xcodeproj
```

In Xcode, pick **My Mac** and Run. On first run macOS blocks screen capture until you grant permission: **System Settings ▸ Privacy & Security ▸ Screen Recording**, enable **Portview Host.app**, fully quit/reopen the app if macOS asks, then run again. The host window shows the address, pin, and pairing URL.

Developer CLI fallback:

```bash
swift run portview-host
```

The CLI still works for development, but Screen Recording permission attaches to your terminal app rather than Portview. Prefer `PortviewHost.app` for device testing.

When ready, the host shows details like:

```
🪟  Portview host ready
 Port:  54321
 Pin:   3a7f…  (64 hex chars)
```

Note the **address**, **pin**, and **pairing URL**. The phone must be on the same Wi-Fi or reach the Mac over your Tailscale.

## 2. Run the iOS client

```bash
cd apps/PortviewClient
xcodegen generate          # regenerates PortviewClient.xcodeproj from project.yml
open PortviewClient.xcodeproj
```

In Xcode: pick your iPhone as the destination, then Run. Use QR pairing, Bonjour discovery, a saved Mac, or manual **IP/port/pin** entry to connect.

To try it in the **iOS Simulator** (host and client on the same Mac), use `127.0.0.1` as the IP.

## Building with your own team

Signing identity for **both** apps is single-sourced in
`apps/Portview.xcconfig` (the client project references it via a
relative `configFiles` path). The tracked defaults are the upstream
maintainer's team (`K7CBQW6MPG`) and bundle-id prefix (`dev.finklea`), so the
maintainer's build stays zero-config.

To build with your own Apple Developer account, **don't edit tracked files** —
create `apps/Portview.local.xcconfig` (gitignored):

```
PORTVIEW_DEVELOPMENT_TEAM = YOURTEAMID
PORTVIEW_BUNDLE_ID_PREFIX = com.yourdomain
```

That overrides the defaults for both apps: bundle ids become
`com.yourdomain.portview` (client), `com.yourdomain.portview.host` (host), and
`com.yourdomain.portview.tests` (client unit tests). The override is resolved
at build time, so you don't need to re-run `xcodegen generate` after creating
or editing it.

## Versioning

`MARKETING_VERSION` (user-facing, e.g. `1.0`) and `CURRENT_PROJECT_VERSION`
(build number, e.g. `1`) also live in `apps/Portview.xcconfig` —
**bump both apps from that one file**. The generated Info.plists reference
`$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`, so a bump takes effect
on the next build; no `xcodegen generate` re-run needed.

TestFlight readiness: each app ships a `PrivacyInfo.xcprivacy` (no tracking,
no data collection; declares UserDefaults `CA92.1` on the client and
`systemUptime` `35F9.1` on both) and sets `ITSAppUsesNonExemptEncryption` to
`false` (standard TLS-only exemption). Archive/upload validation against App
Store Connect has not been run yet.

## Preflight gate (no hosted CI yet)

There is deliberately no GitHub Actions workflow (hosted macOS-26 runners are unreliable). Run the full gate locally from the repo root:

```bash
make preflight   # swift test + macOS host build + iOS simulator tests
```

To run it automatically before every push, install the pre-push hook (either way):

```bash
cp scripts/pre-push .git/hooks/pre-push
# or
git config core.hooksPath scripts
```

## What works / what's next

- ✅ Live screen view, trackpad/keyboard control, clipboard, audio, file transfer, multi-monitor, QUIC transport, Metal renderer, diagnostics HUD.
- ⏭️ Next: on-device motion/quality retest, QUIC validation over real/Tailscale link, then adaptive bitrate/fps polish. See `.docs/ai/roadmap.md`.

# Running Portview (POC)

Portview is two apps over a shared, tested core (`PortviewProtocol`, `PortviewTransport`, `PortviewMedia`, `PortviewHostCore`):

- **Mac host** (`apps/PortviewHost`) — a signed macOS app that captures the screen, hardware-HEVC-encodes it, and serves it under Portview's own Screen Recording identity.
- **iOS client** (`apps/PortviewClient`) — a SwiftUI app that connects, decodes, and displays the Mac's screen.

> **Approaching v1.0.** The core pipeline (capture → HEVC encode → certificate-pinned QUIC → HEVC decode → display/control) is wired end to end, behind mutual authentication (attended enrollment + revocation). Bonjour discovery, QR/SAS pairing, clipboard, audio, file transfer, multi-monitor, Metal rendering, and the diagnostics HUD are implemented. The current focus is on-device verification of the full feature surface.

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

Two caveats on the CLI: Screen Recording permission attaches to your terminal app rather than
Portview, and **the CLI cannot enroll new devices** — it has no pairing UI, so it serves only
devices already enrolled through the app (and needs a restart to pick up enrollments made while
it was running). Pair through `PortviewHost.app` first; prefer the app for device testing.

When ready, the host prints a banner with its **address**, Bonjour **service name**, grouped
**pin**, and the full **pairing URL** (plus a scannable QR in the terminal). The phone must be
on the same Wi-Fi or reach the Mac over your Tailscale.

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

There is deliberately no GitHub Actions workflow. Hosted macOS-26 runners are unreliable, and
the package suite needs a real Keychain (`KeychainIdentityStoreTests` exercises live `SecItem`
on purpose), loopback QUIC listeners, and a hardware HEVC encoder — none of which a hosted
runner provides. Run the full gate locally instead.

**Fresh clone — run this first.** Both `.xcodeproj` bundles are generated from `project.yml`
and are not tracked, so the `xcodebuild` legs have nothing to point at until you generate them:

```bash
make bootstrap   # verifies xcodegen, generates both projects, arms the pre-push gate
```

Then, from the repo root:

```bash
make preflight   # swift test + macOS host build + macOS host tests + iOS simulator tests
```

`make bootstrap` sets `core.hooksPath=scripts`, so `scripts/pre-push` runs `make preflight`
before every push. To arm it without the rest of bootstrap:

```bash
git config core.hooksPath scripts
```

`make generate` regenerates the projects on their own; it re-runs `xcodegen` only when a
`project.yml` or `apps/Portview.xcconfig` is newer than the generated project.

## What works / what's next

- ✅ Live screen view, trackpad/keyboard control, clipboard, audio, file transfer, multi-monitor, QUIC transport, Metal renderer, diagnostics HUD.
- ✅ Mutual auth: per-device keypairs, attended Touch ID-gated enrollment, live-session revoke, break-glass reset — device-verified. Notarized Developer-ID host build (`make release`).
- ⏭️ Next: full on-device feature sweep, Tailscale validation, host settings (launch at login), clipboard/files opt-in, iOS first-run walkthrough. See `.docs/ai/roadmap.md`.

# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-06-02

- Brainstormed Porthole from scratch (greenfield). Locked all product decisions (see `decisions.md`).
- Ran a 70-agent research workflow on Apple screen-sharing protocols / capture / iOS / transport / prior art; it validated the own-host-agent + QUIC + HEVC direction.
- Wrote canonical design spec: `docs/superpowers/specs/2026-06-02-porthole-design.md`.
- Scaffolded repo: LICENSE (Apache-2.0), README, .gitignore, `.docs/ai/`.
- Next: writing-plans → implement M0 (PortholeProtocol package, TDD).

## Build Status

- 🎉 **HARDWARE-VERIFIED 2026-06-02:** full POC works on a real iPhone → Mac — live HEVC screen repainting **and** trackpad control (move/click/scroll via CGEvent), connected via QR pairing. M0 + M1 confirmed end-to-end on device. (Bug found & fixed during the live run: encoder must match the capture buffer's pixel size, not `display.width` points — Retina mismatch was dropping every frame; commit `7752b61`. Accessibility + Screen-Recording grants both working.)
- **Keyboard typing + pinch-zoom-follows-cursor IMPLEMENTED + compiling (55 tests / 19 suites):** protocol gained `KeyEvent` (special keys: return/delete/tab/escape/arrows) + `CursorPosition` (host→client, normalized). Host `InputInjector` injects special keys (CGEvent virtualKey) and reports cursor position (throttled). Client: on-screen keyboard via a `UIKeyInput` first-responder (insertText→typeText, deleteBackward/return→KeyEvent) toggled by a toolbar button; pinch-to-zoom on the video with a clamped layer transform that keeps the host cursor centered when zoomed. NOT yet hardware-verified (restart host + rebuild client to try). Note: zoom cursor-follow approximates the cursor in view-bounds space (ignores letterbox) — refine if off.

- Toolchain: Swift 6.2, Xcode 26.0.1, macOS 26.3.1 (Apple Silicon). Confirmed.
- `PortholeProtocol` package: builds clean, `swift test` = 31/31 green (9 suites). Wire protocol complete — binary primitives, 6 M0 messages, self-delimiting framing, FrameDecoder stream reassembly, client/server handshake state machines, e2e handshake-over-frames. (Plan: `docs/superpowers/plans/2026-06-02-porthole-protocol.md`, executed.)
- `PortholeTransport`: IMPLEMENTED. 36 tests / 13 suites all green. TLS identity (RSA self-signed via openssl→PKCS#12→SecPKCS12Import), QUIC loopback spike (one-way, proves QUIC works), cert pinning (SHA-256 of leaf DER), MessageChannel, and `PortholeConnection`/`PortholeListener` carrying the full handshake + a VideoFrame over a real localhost connection.
- **POC transport = TLS-over-TCP** (see decisions.md): bidirectional, unambiguous; QUIC's bare-NWConnection+listener model double-delivers connections and the reply-send hangs (needs the NWConnectionGroup/NWMultiplexGroup multiplex model, deferred). PortholeConnection is transport-agnostic, so swapping back to QUIC is one line. QUICParameters + the QUIC loopback spike remain as proven groundwork.
- `PortholeMedia`: IMPLEMENTED + the **core pipeline POC passes**. VideoToolbox hardware HEVC encode + decode (synthetic-frame round-trip recovers color), HEVC sample serialization (parameter sets + AVCC data ↔ bytes), and a full end-to-end test: frame → encode → serialize → VideoFrame over pinned-TLS PortholeConnection → deserialize → decode → color verified. All autonomous (no TCC/GUI).
- **POC STATUS: the entire core pipeline (encode → secure transport → decode) is proven by tests.** Remaining for a watchable demo (need your hardware): real screen capture (ScreenCaptureKit + Screen-Recording grant), on-screen render (Metal/CAMetalLayer), and packaging the macOS host + iOS client apps (Xcode + device).
- `porthole-host` (macOS `swift run` executable): IMPLEMENTED + compiles. CaptureEngine (ScreenCaptureKit SCStream → CVPixelBuffer, drop-stale buffering) → VideoEncoder → VideoSampleSerializer → PortholeListener; does the server handshake then streams VideoFrames; prints cert pin + port. ScreenCaptureKit imported `@preconcurrency` (Apple hasn't Sendable-annotated it for Swift 6). NOT run-verified (needs Screen-Recording grant — `swift run porthole-host`, then grant in System Settings, re-run).
- Shared packages gated for iOS: TLSIdentity openssl/Process code is `#if os(macOS)` (client never mints an identity), so PortholeProtocol/Transport/Media compile for iOS.
- iOS client app (`apps/PortholeClient`, xcodegen): SCAFFOLDED + **compiles for iOS 26 simulator (BUILD SUCCEEDED)**. SwiftUI connect screen (IP/port/pin) + SessionViewModel (connect → client handshake → receive VideoFrame → deserialize → enqueue) + AVSampleBufferDisplayLayer renderer. Generated .xcodeproj is gitignored — run `xcodegen generate` in apps/PortholeClient. Run guide: `apps/README.md`.
- **M0 walking-skeleton scaffold COMPLETE and compiling end to end.** Not yet run on real hardware (needs Screen-Recording grant on the Mac + iPhone/Xcode for the client). To watch live: `swift run porthole-host` (grant Screen Recording, re-run), then run the iOS app and enter the printed IP/port/pin.
- **M1 control IMPLEMENTED + compiling (full suite 46 tests / 17 suites green):** input protocol messages (pointerMove/pointerButton/scroll/typeText — TDD); host `InputInjector` maps them to CGEvents (relative cursor w/ clamping, click, scroll, unicode type) — host `serve()` now handles input concurrently with the video pump; needs Accessibility grant (host prints a hint). Client: `TrackpadVideoView` — 1-finger drag = move, tap = click, 2-finger = scroll → input messages. iOS app bundle id = `dev.finklea.porthole`, automatic signing team K7CBQW6MPG.
- Fixed a flaky `SecPKCS12Import` race under concurrent test suites by serializing it with a lock (`TLSIdentity.importLock`); 3 consecutive full-suite runs green.
- Host needs BOTH grants to fully work: Screen Recording (capture) + Accessibility (input). Both attach to the terminal app for `swift run`.
- **M1 frictionless connect IMPLEMENTED + compiling (50 tests / 18 suites green):** host advertises Bonjour `_porthole._tcp` and prints a pairing URL + terminal QR; shared `PairingPayload` (URL ↔ host/port/pin, tested) + `PortholeBrowser`; client gets a discovered-Macs list, a camera QR scanner (scan → auto-connect), and manual entry. iOS Info.plist now has NSBonjourServices + NSCameraUsageDescription + NSLocalNetworkUsageDescription (via xcodegen `info:`; generated `*-Info.plist` is gitignored). *(QR scannability + camera unverified — need a device.)*
- Next: run M0/M1 on hardware; then M1 polish (on-screen keyboard UI, saved-Macs list, device keypairs + revocable PairingStore) and M2+ (clipboard/audio/files/multi-monitor); revisit QUIC + Metal renderer.

## Blockers

- None.

## Verified SDK facts (macOS 26.0 SDK, by reading headers)

- QUIC datagrams ARE supported in Network.framework (`NWProtocolQUIC.Options.maxDatagramFrameSize`/`.isDatagram`/`.usableDatagramFrameSize`; `nw_quic_*` in quic_options.h). BUT: only one datagram flow per connection and frames are MTU-bounded (~1200 B) << a video keyframe. → v1 video lane = one short-lived **unidirectional QUIC stream per frame** (no cross-frame HoL; abandon stale via reset). Datagrams reserved as a future sub-frame optimization.
- Two QUIC API generations exist: classic `NWConnection`/`NWListener` + `NWProtocolQUIC.Options` (chosen for v1 — stable, documented) and the new Swift-first `NetworkConnection`/`NetworkListener` + `QUIC`/`QUICDatagram` builders (future swap, insulated behind our own transport types).

## Open questions (resolve during build)

- ~~iOS 26 QUIC datagrams?~~ RESOLVED: supported; not used in v1 (see above).
- Exact `SecIdentity` self-signed creation + `NWMultiplexGroup` stream-open signatures on macOS 26 → verify in transport Task 1 spike (do not prescribe from memory).
- `EnableLowLatencyRateControl` covers HEVC on macOS 26? (else pin H.264 for low-latency path) — resolve when building the host encoder.

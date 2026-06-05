# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Latest Session (2026-06-05 — video quality diagnostics)

User device-tested latest app: zoom is better but still softer/blurry vs VNC. Chose instrumentation before more features.

- Added `QualityStats` protocol msg (19) + tests; host emits ~1 Hz encoder stats: configured bitrate, actual encoded Mbps/fps, avg bytes/frame, keyframes, avg encode ms, encoder dimensions, active viewport.
- Client computes receive Mbps/fps, bpp/frame, avg decode ms, frame size; streaming toolbar gauge toggles a compact Quality HUD.
- Metal renderer now has runtime sampler toggle (Linear ↔ Nearest) while HUD is visible; use this to distinguish encoded softness from final texture filtering.
- Verify run: `swift test --package-path /Users/tfinklea/git/screenshare` → 74 tests / 26 suites green. `xcodegen generate`; `xcodebuild ... -destination "generic/platform=iOS Simulator" ... build` → BUILD SUCCEEDED.
- Next device run: zoom into text, open HUD, capture Host/Recv Mbps, Host bpp/Client bpp, encode/decode ms, crop, sampler mode, and whether Nearest looks materially sharper.

## Previous Session (2026-06-02 #3 — QUIC swap + zoom fixes)

User confirmed all "do all of it" features work on device. Then: "switch to QUIC and actually test it" + "zoomed-in experience is still terrible."

- **QUIC is now the DEFAULT transport** (commit `beced46`). Ran a 6-candidate empirical loopback sweep (parallel worktrees). Breakthrough: the `NWConnectionGroup`/`NWMultiplexGroup` model was a **red herring** — a bare `NWConnection(to:using:QUICParameters.client)` is itself one bidirectional QUIC stream and carries a full round-trip. The real gotcha is QUIC's server-side **double-delivery** (`newConnectionHandler` fires twice: a dead "control" connection + the real data one) — fixed by the host serving each accepted connection **concurrently** (`Task { serve }`). Client uses `connectQUIC`, host uses `PortviewListener(quicIdentity:)`. Dead multiplex scaffolding removed. Bonjour type → `_portview._udp` (+ NSBonjourServices). `QUICBidirectionalTests` ENABLED + green. TLS-over-TCP kept as one-call fallback. See decisions.md ADR. **Tests 70/25 green; host + iOS build clean.** ⚠️ QUIC not yet validated on a real/Tailscale link (only loopback) — needs on-device test.
- **Zoom — jumpy + off-center FIXED** (commit `689b253`, client-only): off-center was a real bug (pan math centered against full view bounds, ignoring the Metal letterbox) — now centers against the actual aspect-fit video rect with correct clamping; jumpy → short critically-damped spring on the pan offset. Verified iOS build.
- **Zoom — blurry = FIXED via host-side magnifier** (commit `235bb88`, user chose "build full magnifier now"). New `Viewport` msg (18, normalized, both directions): client sends target crop (1/zoom, cursor-centered, throttled ~12 Hz); host sets `SCStreamConfiguration.sourceRect` to it (output dims constant → region encoded at full res → crisp) and confirms when applied. Client renders a **residual** transform (residual zoom = frameViewport.w / target.w) → instant digital zoom during the pinch that settles to crisp host-cropped 1:1 when frame==target. Adversarial multi-agent review (12 agents) found+fixed 4 real issues: setViewport is `async -> Bool` awaited in-order in the inbound loop (no orphaned/racing confirm Tasks), confirms only on updateConfiguration success (no phantom-crop settle), dedup+1% near-full threshold (no reconfig thrashing). **Tests 72/25 green; host + iOS build clean.**
  - **ON-DEVICE (user, 2026-06-03):** "a lot better… usable." Reported 3 limitations → all addressed in the **zoom overhaul** (commit `fad89a6`, build-green, device-verify pending):
    - **#1 aspect/fill:** new `ZoomGeometry` **window model** — view-aspect window sized by 1/zoom; zoom 1 = whole display (overview, unchanged), zooming shrinks the window toward the phone aspect so the **letterbox bars shrink to none**. Rendered via uniform renderScale+pan mapped through the host crop (re-crop changes crispness, not position → no jerk; continuous from zoom-1, no jump). Chose this over the two-mode view-aspect host output (smoother, no rebuild churn).
    - **#2 jerky:** visual decoupled from host re-crop; crop padded 1.4×; throttle 80→120 ms.
    - **#3 pixelated:** `VideoEncoder` now sets an explicit AverageBitRate (w·h·6, 8–50 Mbps; set none before → soft default).
    - Adversarially reviewed (no geometry bugs).
  - **ON-DEVICE #2 (user, 2026-06-03):** fill works great, but still blurry at moderate zoom. Tried tight-crop/native-res host output (`4591ef7`) — **it "looked worse" on device + the host CRASHED**, so:
  - **ON-DEVICE #3 (user, 2026-06-04):**
    - **CRASH FIXED** (`d6996bd`): `ClipboardSync` polled `NSPasteboard` on a background Task thread → AppKit memory corruption (`pointer being freed was not allocated` → SIGABRT at ClipboardSync.swift:22). Fix: all NSPasteboard access on the **main actor** (`Task { @MainActor in }`). *(Latent since the clipboard feature; fired when the pasteboard changed during a session.)*
    - **Tight-crop REVERTED** (`e02482e`): post-mortem — the blur is **bitrate-bound, not resolution-bound**. The whole display was encoded at native res but ~0.1 bpp (soft text); the tight crop shrank buffer + bitrate proportionally so bpp didn't improve, and re-encode churn made it worse. Back to the known-good window model.
    - **Crispness fix that shipped** (`5b11c69`): raised encoder bitrate ~0.1→~0.3 bpp (w·h·18, clamp 12–80 Mbps) — LAN/QUIC has bandwidth to spare; the full display is encoded crisper and the client digitally zooms in. Tunable on device.
    - **Tests 72/25 green; host + iOS build clean.** Device-verify pending. Further crispness lesson in roadmap: keep bitrate HIGH while cropping (per-region rate), don't scale it down with the buffer.

## Previous Session (2026-06-02 — "do all of it")

Worked the full remaining backlog sequentially. **All 9 items done + committed** on top of the hardware-verified POC. **Tests: 69 / 24 suites green (1 QUIC test intentionally disabled). Host builds clean. iOS app BUILD SUCCEEDED.**

- **Clipboard sync (M2)** — `ClipboardUpdate` msg (13); host `ClipboardSync` polls NSPasteboard changeCount → push, applies remote without echo; client writes UIPasteboard inbound + "paste to Mac" button. Commit `0865234`. *(Also fixed a real bug: host input case list was missing `.keyEvent` → backspace/return/arrows were never injected.)*
- **Modifier keys / chords (⌘⇧⌥⌃)** — `KeyModifiers` OptionSet; `KeyEvent` carries modifiers + either a SpecialKey OR a character (⌘C works). Host CGEventFlags + ANSI/US keycode table. Client sticky modifier bar (arm → next key is a chord → auto-clears). Commit `624d821`.
- **2-finger scroll vs pinch-zoom** — per-gesture intent-lock in `TrackpadVideoView.Coordinator` (first decisive signal wins; loser no-ops until fingers lift; baselines rebased). Commit `9b23eed`.
- **Saved-Macs list** — `SavedHostsStore` (UserDefaults JSON); "Saved Macs" section (one-tap reconnect, swipe-delete); persisted only on `.streaming` (never a bad pin). Commit `997972b`.
- **Multi-monitor (M3)** — host advertises ALL displays in ServerHello, picks by StartSession.displayID; new `SwitchDisplay` msg (14) re-targets capture + rebinds InputInjector live; pumpVideo breaks on cancel. Client display-switcher Menu. Commit `23bc418`.
- **File transfer (M5)** — iPhone→Mac push; `FileOffer`(15)+`FileChunk`(16); host `FileReceiver` writes ~/Downloads (de-dups names); client `.fileImporter` + 64 KB ordered chunks interleaved with video. Commit `614dd39`. *(Mac→iPhone = future.)*
- **Metal renderer** — replaced AVSampleBufferDisplayLayer with explicit `VideoDecoder` (HEVC→BGRA) → `MetalVideoRenderer` (CVMetalTextureCache zero-copy → CAMetalLayer, runtime passthrough shader, aspect-fit). Commit `b2c14f2`.
- **Audio (M4)** — SCStream `capturesAudio`; host converts to non-interleaved Float32 (AVAudioConverter), `AudioFrame`(17); client `AudioPlayer` (AVAudioEngine/PlayerNode). Commit `3dceb0e`. *(Plays as it arrives; tight A/V lip-sync = future.)*
- **QUIC transport (M6) — GROUNDWORK ONLY, not a swap.** Additive `connectQUIC` + `PortviewListener(quicIdentity:)` via NWMultiplexGroup; cancellable `awaitReady`. Loopback bidi test `@Test(.disabled)` because it **reproduced the documented chicken-and-egg** (ready-before-open hangs; open-immediately returns nil/`streamUnavailable`). TLS-over-TCP remains the shipping default — zero regression. See decisions.md ADR. Commit `e441244`.

**⚠️ Not yet hardware-verified (build-green only):** clipboard, modifiers, gestures, saved-Macs, multi-monitor, file transfer, **Metal render path** (replaced the proven AVSampleBufferDisplayLayer — check video still paints on device), and **audio** (needs device + Screen-Recording grant + real audio source). Re-run host (`swift run portview-host`, grant Screen Recording) + rebuild client on device to validate.

## Last Session Summary

**Date**: 2026-06-02

- Brainstormed Portview from scratch (greenfield). Locked all product decisions (see `decisions.md`).
- Ran a 70-agent research workflow on Apple screen-sharing protocols / capture / iOS / transport / prior art; it validated the own-host-agent + QUIC + HEVC direction.
- Wrote canonical design spec: `docs/superpowers/specs/2026-06-02-portview-design.md`.
- Scaffolded repo: LICENSE (Apache-2.0), README, .gitignore, `.docs/ai/`.
- Next: writing-plans → implement M0 (PortviewProtocol package, TDD).

## Build Status

- 🎉 **HARDWARE-VERIFIED 2026-06-02:** full POC works on a real iPhone → Mac — live HEVC screen repainting **and** trackpad control (move/click/scroll via CGEvent), connected via QR pairing. M0 + M1 confirmed end-to-end on device. (Bug found & fixed during the live run: encoder must match the capture buffer's pixel size, not `display.width` points — Retina mismatch was dropping every frame; commit `7752b61`. Accessibility + Screen-Recording grants both working.)
- **Keyboard typing + pinch-zoom-follows-cursor IMPLEMENTED + compiling (55 tests / 19 suites):** protocol gained `KeyEvent` (special keys: return/delete/tab/escape/arrows) + `CursorPosition` (host→client, normalized). Host `InputInjector` injects special keys (CGEvent virtualKey) and reports cursor position (throttled). Client: on-screen keyboard via a `UIKeyInput` first-responder (insertText→typeText, deleteBackward/return→KeyEvent) toggled by a toolbar button; pinch-to-zoom on the video with a clamped layer transform that keeps the host cursor centered when zoomed. NOT yet hardware-verified (restart host + rebuild client to try). Note: zoom cursor-follow approximates the cursor in view-bounds space (ignores letterbox) — refine if off.

- Toolchain: Swift 6.2, Xcode 26.0.1, macOS 26.3.1 (Apple Silicon). Confirmed.
- `PortviewProtocol` package: builds clean, `swift test` = 31/31 green (9 suites). Wire protocol complete — binary primitives, 6 M0 messages, self-delimiting framing, FrameDecoder stream reassembly, client/server handshake state machines, e2e handshake-over-frames. (Plan: `docs/superpowers/plans/2026-06-02-portview-protocol.md`, executed.)
- `PortviewTransport`: IMPLEMENTED. 36 tests / 13 suites all green. TLS identity (RSA self-signed via openssl→PKCS#12→SecPKCS12Import), QUIC loopback spike (one-way, proves QUIC works), cert pinning (SHA-256 of leaf DER), MessageChannel, and `PortviewConnection`/`PortviewListener` carrying the full handshake + a VideoFrame over a real localhost connection.
- **POC transport = TLS-over-TCP** (see decisions.md): bidirectional, unambiguous; QUIC's bare-NWConnection+listener model double-delivers connections and the reply-send hangs (needs the NWConnectionGroup/NWMultiplexGroup multiplex model, deferred). PortviewConnection is transport-agnostic, so swapping back to QUIC is one line. QUICParameters + the QUIC loopback spike remain as proven groundwork.
- `PortviewMedia`: IMPLEMENTED + the **core pipeline POC passes**. VideoToolbox hardware HEVC encode + decode (synthetic-frame round-trip recovers color), HEVC sample serialization (parameter sets + AVCC data ↔ bytes), and a full end-to-end test: frame → encode → serialize → VideoFrame over pinned-TLS PortviewConnection → deserialize → decode → color verified. All autonomous (no TCC/GUI).
- **POC STATUS: the entire core pipeline (encode → secure transport → decode) is proven by tests.** Remaining for a watchable demo (need your hardware): real screen capture (ScreenCaptureKit + Screen-Recording grant), on-screen render (Metal/CAMetalLayer), and packaging the macOS host + iOS client apps (Xcode + device).
- `portview-host` (macOS `swift run` executable): IMPLEMENTED + compiles. CaptureEngine (ScreenCaptureKit SCStream → CVPixelBuffer, drop-stale buffering) → VideoEncoder → VideoSampleSerializer → PortviewListener; does the server handshake then streams VideoFrames; prints cert pin + port. ScreenCaptureKit imported `@preconcurrency` (Apple hasn't Sendable-annotated it for Swift 6). NOT run-verified (needs Screen-Recording grant — `swift run portview-host`, then grant in System Settings, re-run).
- Shared packages gated for iOS: TLSIdentity openssl/Process code is `#if os(macOS)` (client never mints an identity), so PortviewProtocol/Transport/Media compile for iOS.
- iOS client app (`apps/PortviewClient`, xcodegen): SCAFFOLDED + **compiles for iOS 26 simulator (BUILD SUCCEEDED)**. SwiftUI connect screen (IP/port/pin) + SessionViewModel (connect → client handshake → receive VideoFrame → deserialize → enqueue) + AVSampleBufferDisplayLayer renderer. Generated .xcodeproj is gitignored — run `xcodegen generate` in apps/PortviewClient. Run guide: `apps/README.md`.
- **M0 walking-skeleton scaffold COMPLETE and compiling end to end.** Not yet run on real hardware (needs Screen-Recording grant on the Mac + iPhone/Xcode for the client). To watch live: `swift run portview-host` (grant Screen Recording, re-run), then run the iOS app and enter the printed IP/port/pin.
- **M1 control IMPLEMENTED + compiling (full suite 46 tests / 17 suites green):** input protocol messages (pointerMove/pointerButton/scroll/typeText — TDD); host `InputInjector` maps them to CGEvents (relative cursor w/ clamping, click, scroll, unicode type) — host `serve()` now handles input concurrently with the video pump; needs Accessibility grant (host prints a hint). Client: `TrackpadVideoView` — 1-finger drag = move, tap = click, 2-finger = scroll → input messages. iOS app bundle id = `dev.finklea.portview`, automatic signing team K7CBQW6MPG.
- Fixed a flaky `SecPKCS12Import` race under concurrent test suites by serializing it with a lock (`TLSIdentity.importLock`); 3 consecutive full-suite runs green.
- Host needs BOTH grants to fully work: Screen Recording (capture) + Accessibility (input). Both attach to the terminal app for `swift run`.
- **M1 frictionless connect IMPLEMENTED + compiling (50 tests / 18 suites green):** host advertises Bonjour `_portview._tcp` and prints a pairing URL + terminal QR; shared `PairingPayload` (URL ↔ host/port/pin, tested) + `PortviewBrowser`; client gets a discovered-Macs list, a camera QR scanner (scan → auto-connect), and manual entry. iOS Info.plist now has NSBonjourServices + NSCameraUsageDescription + NSLocalNetworkUsageDescription (via xcodegen `info:`; generated `*-Info.plist` is gitignored). *(QR scannability + camera unverified — need a device.)*
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

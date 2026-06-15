# Roadmap

> Durable goals and milestones. Updated when scope changes, not every session.

## Vision

Portview — open-source, native-feeling iPhone→Mac screen sharing & control (own Mac host agent: ScreenCaptureKit + VideoToolbox HEVC over QUIC; iPhone is pure viewer/controller). Replaces laggy VNC. Apache-2.0. macOS 26 / iOS 26, Apple Silicon.

Full design: `docs/superpowers/specs/2026-06-02-portview-design.md`.

## Now / Next / Later

### Now
- [x] **Glass HUD redesign (both apps)** — DONE (build-green; device-verify pending), 2026-06-15. Recreated the locked "Glass HUD" design (claude.ai/design handoff) in SwiftUI: per-app `GlassTheme`, all 6 iOS screens (Deck Home / Pair-Scan / Connecting / Live Control HUD / Keyboard+Modifiers / Reconnecting) + all 3 macOS host states (Permissions / Ready-to-pair w/ real CoreImage QR / Device-connected). System SF + SF Mono (no bundled fonts); Material glass (not Liquid Glass). Built the two states needing new real model surface: iOS `SessionViewModel.reconnecting` + bounded mid-session Bonjour re-bind, and macOS live device/stats via `HostRunner` events → `HostSessions` reducer → `HostAppModel` + a `HostControl` Disconnect (sends `.bye` so the client doesn't auto-reconnect). No fabricated data (real telemetry; latency omitted not faked). 4-dimension adversarial review: 9/9 confirmed, 5 fixed, 2 deferred (below), 2 no-action. Decision: decisions.md (2026-06-15). Verify: `swift test` 104/33, iOS `xcodebuild test` 17/17, macOS BUILD SUCCEEDED. <!-- device-verify: live IP-change reconnect (degraded→reconnecting→live); host state C with a real connected iPhone (name, ticking mm:ss, stats, Disconnect); the Glass look on a real device -->
- [x] **Persistent host identity + stable port** — DONE (build-green; device-verify pending), commits `909c2a8` (spec) + `e1a9db4` (impl). Spec: `docs/superpowers/specs/2026-06-13-persistent-host-identity-design.md`. `TLSIdentity.loadOrCreatePersistent`/`persistPort` store the openssl p12 blob + bound port as one Keychain generic-password item (re-import on launch; re-mint absent/expired, cert `-days 2`→3650; degrade to ephemeral on Keychain failure). `PortviewListener` gained optional `port:`; `HostRunner` re-binds the persisted port (fallback if taken) and surfaces non-persistence / port-fallback via `HostRunnerEvent.message`. App + CLI use DISTINCT Keychain items. 15-finding adversarial review applied (errSecDuplicateItem, listener-leak, process lock). Tests: 94/32. <!-- device-verify: launch PortviewHost.app, pair, restart app, reconnect from Saved Macs without rescanning → same pin+port -->
- [x] On-device verification of the "do all of it" features — user confirmed all new features work.
- [ ] **On-device video quality diagnosis with HUD** — screenshot #1 showed pure digital zoom into full 1710x1107 frame (`Crop/Frame w1.00`, ~0.06 Mbps actual). Follow-up #1 moved crop but only to `w0.93 h0.93`; screenshot #2 still encoded `1710x1107`, `~0.05 Mbps`, `810 B/f`, `bpp 0.0034`. The full-frame Retina attempt (`SCContentFilter.pointPixelScale` output + encoder quality hints) looked less smooth/jerky and was rolled back. Latest client patch debounces viewport/crop sends until 250 ms idle; latest host packaging adds `PortviewHost.app` so Screen Recording grants attach to Portview instead of Terminal (automated verify: SwiftPM tests 82/28, CLI build, XcodeGen, macOS app BUILD SUCCEEDED). Human device test pending: launch/grant `PortviewHost.app`, confirm movement smoothness first, then record HUD Mbps/B/f/bpp + Crop/Frame; if still soft but smooth, tune effective crop + bitrate/adaptive rate.
- [ ] **On-device test of QUIC + zoom overhaul** — QUIC is now the default transport (only loopback-verified so far): confirm connect/stream/control/clipboard/audio/files all still work over QUIC, ideally over a real/Tailscale link to gauge the latency win. Confirm zoom behavior while collecting HUD data.

### Next
- [ ] QUIC lane-splitting (per-frame unidirectional video streams); validate QUIC latency over a real/Tailscale link.
- [ ] Mac→iPhone file transfer; tight A/V lip-sync.
- [ ] Magnifier follow-ups (if on-device testing shows them): tune the residual-settle timing; consider raising encode bitrate when cropped; smooth the crop transition.
- [x] **IP stability** (split out of the persistent-identity work) — DONE (build-green; device-verify pending), commit `4fe9d79`. Saved-Mac reconnect now prefers a live Bonjour host matching by name (re-resolves the current IP), then the saved `host:port` fallback; pin unchanged so cert pinning still gates. Decision in decisions.md (2026-06-14). <!-- follow-up below: refresh the stored fallback IP after a Bonjour reconnect -->
- [ ] **Expose the resolved remote endpoint on `PortviewConnection`** (review-flagged, deferred) — unblocks TWO things that both need the live connection's `currentPath?.remoteEndpoint`: (a) **refresh saved fallback IP after a Bonjour reconnect** — after re-binding to a new IP the saved entry keeps the OLD IP (harmless on-LAN since name-rediscovery always works, but the off-LAN fallback + UI subtitle go stale); (b) **persist a discovery-paired Mac** — tapping a Bonjour-discovered Mac + entering a pin streams fine but is never saved, because its `NWEndpoint` is a `.service` case with no `host:port` to build a `PairingPayload` from; the resolved endpoint would give the concrete `host:port` to remember on first stream (Glass-HUD review finding #2). `tier_floor: senior`, `complexity: S`.
- [ ] **Serialize all outbound input through one ordered consumer** (Glass-HUD review #3, hardening) — `SessionViewModel.send()` spawns a Task per message, so pointer-move vs click/scroll/key ordering can race (the down/up *pair* is already fixed by sending both in one Task). Full fix: push outbound input into an `AsyncStream` drained by one Task that awaits each `connection.send` in turn. `tier_floor: senior`, `complexity: S`. Low priority (human-paced input rarely races).

### Later
- [ ] M6 polish: adaptive bitrate/fps, reconnect + APNs re-wake, settings, TCC onboarding UI. Device keypairs + revocable PairingStore. *(Quality HUD now exists as dev diagnostics; product polish still TBD.)*

## Milestones

### M0: Walking skeleton
- [x] `PortviewProtocol`: lane defs, message types, binary framing, handshake state machine, version negotiation (pure Swift, unit-tested) — 31 tests green
- [x] `PortviewTransport`: connection/listener wrapper over Network.framework — TLS-over-TCP for the POC (QUIC groundwork proven via one-way loopback spike; see decisions.md), cert pinning, handshake + VideoFrame over a real connection. 36 tests green.
- [x] `PortviewMedia`: VideoToolbox HEVC encode + decode (round-trip recovers color); HEVC sample serialization; **full encode→pinned-TLS→decode pipeline POC, color-verified, autonomous**.
- [x] Host: `portview-host` exe — SCStream capture → VideoEncoder → serialize → serve. Compiles; runs with a Screen-Recording grant.
- [x] Client: iOS app — receive → deserialize → AVSampleBufferDisplayLayer render. Compiles for iOS 26 sim (BUILD SUCCEEDED). *(CAMetalLayer is a later latency optimization.)*
- [x] Package macOS host (`PortviewHost.app` + SwiftPM CLI fallback) + iOS client app (xcodegen). Run guide: `apps/README.md`. *(Running on a real iPhone needs Xcode + your signing team.)*
- [ ] Latency harness; confirm <50 ms motion-to-photon
- [x] Resolve open Qs: iOS 26 QUIC datagrams (supported; deferred) ✓; HEVC encode works on macOS 26 ✓ (EnableLowLatencyRateControl accepted)

### M1: Control + connect
- [x] InputInjector (CGEvent global coords) + input lane (pointerMove/pointerButton/scroll/typeText) + trackpad gesture→message mapping. Host injection + client trackpad compile; 46 tests. *(Injection needs Accessibility grant; run-verify on hardware pending.)*
- [x] On-screen keyboard UI — `UIKeyInput` first-responder; typeText + `KeyEvent` special keys (return/delete/tab/escape/arrows) + host CGEvent injection. *(Secure-Input detection/banner still to do.)*
- [x] Pinch-to-zoom on the video that follows the cursor (host reports `CursorPosition`; client clamped layer transform). *(Approximates view-bounds, ignores letterbox; hardware-verify pending.)*
- [x] Bonjour advertise (`_portview._tcp`) + NWBrowser discovery + client list; manual IP/port retained. *(LAN-functional verify needs devices.)*
- [x] QR pairing — host terminal QR + pairing URL (`PairingPayload`); client camera scanner → auto-connect. Cert pinning enforced. *(Device keypairs + revocable PairingStore still to do.)*
- [x] Saved-Macs list (`SavedHostsStore`, UserDefaults; one-tap reconnect, persists on successful stream). Persistence bug fixed 2026-06-05: QR/manual pending pairings now survive the connect-form → streaming view switch and commit only after `.streaming`.
- [x] Modifier keys / chords (⌘⇧⌥⌃) — `KeyModifiers` + char-or-special `KeyEvent`; host CGEventFlags + ANSI keycodes; client sticky modifier bar.
- [x] Separate 2-finger scroll from pinch-zoom (per-gesture intent lock).

### M2: Clipboard sync (text, both ways) — [x] DONE
Text both ways: `ClipboardUpdate` msg, host `ClipboardSync` (NSPasteboard poll + apply), client UIPasteboard + "paste to Mac" button.

### M3: Multi-monitor (pick/switch display) — [x] DONE (build-green; device-verify pending)
Host advertises all displays; `SwitchDisplay` msg re-targets capture + InputInjector live; client display-switcher Menu.

### M4: Audio (Mac → iPhone) — [x] DONE (build-green; device-verify pending)
SCStream `capturesAudio` → non-interleaved Float32 (AVAudioConverter) → `AudioFrame` → client AVAudioEngine. *(Plays as it arrives; tight lip-sync = future.)*

### M5: File transfer (files lane) — [x] DONE (iPhone→Mac; Mac→iPhone future)
`FileOffer`/`FileChunk`; host `FileReceiver` → ~/Downloads; client `.fileImporter` + chunked send interleaved with video.

### Render: Metal — [x] DONE (build-green; device-verify pending)
Explicit VideoToolbox decode (BGRA) → CAMetalLayer via CVMetalTextureCache. Replaced AVSampleBufferDisplayLayer.

### M6: QUIC transport — [x] DEFAULT (build-green; loopback-verified; on-device pending)
Bare QUIC `NWConnection` (one bidi stream — no multiplex group needed); host serves connections concurrently to tolerate QUIC double-delivery. `connectQUIC` + `PortviewListener(quicIdentity:)` are the default; TLS-over-TCP is a one-call fallback. Bonjour `_udp`. `QUICBidirectionalTests` enabled + green. See decisions.md.

### M6: Polish (adaptive bitrate/fps, reconnect + APNs re-wake, settings, quality HUD) — not started

## Zoom overhaul — [x] DONE (build-green; device-verify pending), commit `fad89a6`
All three on-device complaints addressed via the **client window model** (`ZoomGeometry`):
- **Fill the phone aspect (#1):** view-aspect "window" over the display, sized by 1/zoom; zoom 1 = whole display (overview, letterboxed, unchanged), and as you zoom the window shrinks toward the phone aspect so the **letterbox bars shrink continuously to none**. Rendered aspect-fit, mapped through the host crop (`frameViewport`) via uniform renderScale+pan — host re-cropping changes crispness without moving the picture (so no jerk from reconfig). Continuous from zoom-1 overview (no jump). *(Chose this over the originally-noted two-mode view-aspect host output — it's smoother and avoids the overview→zoom jump + encoder-rebuild churn.)*
- **Jerky (#2):** visual decoupled from host re-crop timing; crop request padded 1.4×; throttle eased 80→120ms.
- **Pixelated (#3):** `VideoEncoder` now sets an explicit AverageBitRate (w·h·6, 8–50 Mbps) — it set none before (soft default). Host crop encodes the zoomed region at that bitrate.
Adversarially reviewed (no geometry bugs found). **Tests 72/25; host + iOS build clean.**

### Zoom crispness — attempt 1 REVERTED, then fixed via bitrate
- **Tight-crop / native-res host output (`4591ef7`) — REVERTED (`e02482e`).** On device it "looked worse" (+ a separate crash). Post-mortem: the blur was **bitrate-bound, not resolution-bound** — the whole display was already encoded at native res, just at ~0.1 bits/pixel (soft text). The tight crop shrank the buffer AND proportionally shrank the bitrate (heuristic w·h·6), so bits/pixel didn't improve, and the per-zoom re-encode added churn. Reverted to the known-good window model.
- **Fix that shipped (`5b11c69`):** raised the encoder bitrate heuristic ~0.1→~0.3 bpp (w·h·18, clamped 12–80 Mbps). On LAN/QUIC bandwidth isn't the constraint; the whole display is encoded crisper and the client digitally zooms into it → crisper zoomed text. Build-green, device-verify pending; multiplier/clamp is tunable.
- **Lesson:** for further crispness, the right path is *higher bits-per-pixel for the visible region* — e.g. keep the bitrate HIGH while cropping (don't scale it down with the buffer), or per-region rate control. A tight crop only helps if its bitrate stays high.

### Backlog — zoom follow-ups (deferred)
- **Adaptive bitrate** when cropped (raise further at high zoom); dynamic `kVTCompressionPropertyKey_AverageBitRate` without recreating the session.
- **Jerky tuning** if still present on device: predictive/leading viewport, interpolate `frameViewport` between host confirmations, raise fps. Smooth the brief rebuild on zoom steps.

## Backlog

> (none open — see zoom follow-ups above)

## Constraints

- Apple Silicon only; macOS 26+ / iOS 26+. Swift 6.2 / Xcode 26.
- Mac must be logged in (no pre-login capture / no remote-unlock — hard public-API limit).
- iOS session is foreground-only (background suspends + drops connection; re-wake via push).
- No servers we host; remote is the user's own overlay VPN.
- Permissive license → clean-room only (no GPL refs like Lumen/Moonlight).

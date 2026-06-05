# Roadmap

> Durable goals and milestones. Updated when scope changes, not every session.

## Vision

Portview — open-source, native-feeling iPhone→Mac screen sharing & control (own Mac host agent: ScreenCaptureKit + VideoToolbox HEVC over QUIC; iPhone is pure viewer/controller). Replaces laggy VNC. Apache-2.0. macOS 26 / iOS 26, Apple Silicon.

Full design: `docs/superpowers/specs/2026-06-02-portview-design.md`.

## Now / Next / Later

### Now
- [x] On-device verification of the "do all of it" features — user confirmed all new features work.
- [ ] **On-device video quality diagnosis with HUD** — screenshot #1 showed pure digital zoom into full 1710x1107 frame (`Crop/Frame w1.00`, ~0.06 Mbps actual). Follow-up build captures backing pixels when available, tightens high-zoom crop, forces keyframe after crop, raises max zoom to 6x, and shows 4-decimal bpp. Device test: confirm encoder size >1710x1107 if available; confirm Crop/Frame <1.00 at 4x/6x after settle; record clarity + Host/Recv Mbps + bpp.
- [ ] **On-device test of QUIC + zoom overhaul** — QUIC is now the default transport (only loopback-verified so far): confirm connect/stream/control/clipboard/audio/files all still work over QUIC, ideally over a real/Tailscale link to gauge the latency win. Confirm zoom behavior while collecting HUD data.

### Next
- [ ] QUIC lane-splitting (per-frame unidirectional video streams); validate QUIC latency over a real/Tailscale link.
- [ ] Mac→iPhone file transfer; tight A/V lip-sync.
- [ ] Magnifier follow-ups (if on-device testing shows them): tune the residual-settle timing; consider raising encode bitrate when cropped; smooth the crop transition.

### Later
- [ ] M6 polish: adaptive bitrate/fps, reconnect + APNs re-wake, settings, TCC onboarding UI. Device keypairs + revocable PairingStore. *(Quality HUD now exists as dev diagnostics; product polish still TBD.)*

## Milestones

### M0: Walking skeleton
- [x] `PortviewProtocol`: lane defs, message types, binary framing, handshake state machine, version negotiation (pure Swift, unit-tested) — 31 tests green
- [x] `PortviewTransport`: connection/listener wrapper over Network.framework — TLS-over-TCP for the POC (QUIC groundwork proven via one-way loopback spike; see decisions.md), cert pinning, handshake + VideoFrame over a real connection. 36 tests green.
- [x] `PortviewMedia`: VideoToolbox HEVC encode + decode (round-trip recovers color); HEVC sample serialization; **full encode→pinned-TLS→decode pipeline POC, color-verified, autonomous**.
- [x] Host: `portview-host` exe — SCStream capture → VideoEncoder → serialize → serve. Compiles; runs with a Screen-Recording grant.
- [x] Client: iOS app — receive → deserialize → AVSampleBufferDisplayLayer render. Compiles for iOS 26 sim (BUILD SUCCEEDED). *(CAMetalLayer is a later latency optimization.)*
- [x] Package macOS host (SwiftPM exe) + iOS client app (xcodegen). Run guide: `apps/README.md`. *(Running on a real iPhone needs Xcode + your signing team.)*
- [ ] Latency harness; confirm <50 ms motion-to-photon
- [x] Resolve open Qs: iOS 26 QUIC datagrams (supported; deferred) ✓; HEVC encode works on macOS 26 ✓ (EnableLowLatencyRateControl accepted)

### M1: Control + connect
- [x] InputInjector (CGEvent global coords) + input lane (pointerMove/pointerButton/scroll/typeText) + trackpad gesture→message mapping. Host injection + client trackpad compile; 46 tests. *(Injection needs Accessibility grant; run-verify on hardware pending.)*
- [x] On-screen keyboard UI — `UIKeyInput` first-responder; typeText + `KeyEvent` special keys (return/delete/tab/escape/arrows) + host CGEvent injection. *(Secure-Input detection/banner still to do.)*
- [x] Pinch-to-zoom on the video that follows the cursor (host reports `CursorPosition`; client clamped layer transform). *(Approximates view-bounds, ignores letterbox; hardware-verify pending.)*
- [x] Bonjour advertise (`_portview._tcp`) + NWBrowser discovery + client list; manual IP/port retained. *(LAN-functional verify needs devices.)*
- [x] QR pairing — host terminal QR + pairing URL (`PairingPayload`); client camera scanner → auto-connect. Cert pinning enforced. *(Device keypairs + revocable PairingStore still to do.)*
- [x] Saved-Macs list (`SavedHostsStore`, UserDefaults; one-tap reconnect, persists on successful stream). *(TCC onboarding still to do.)*
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

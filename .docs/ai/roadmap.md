# Roadmap

> Durable goals and milestones. Updated when scope changes, not every session.

## Vision

Portview — open-source, native-feeling iPhone→Mac screen sharing & control (own Mac host agent: ScreenCaptureKit + VideoToolbox HEVC over QUIC; iPhone is pure viewer/controller). Replaces laggy VNC. Apache-2.0. macOS 26 / iOS 26, Apple Silicon.

Full design: `docs/superpowers/specs/2026-06-02-portview-design.md`.

## Now / Next / Later

### Now
- [x] On-device verification of the "do all of it" features — user confirmed all new features work.
- [ ] **On-device test of QUIC + zoom overhaul** — QUIC is now the default transport (only loopback-verified so far): confirm connect/stream/control/clipboard/audio/files all still work over QUIC, ideally over a real/Tailscale link to gauge the latency win. Confirm the zoom overhaul: jumpy/off-center fixes + the host-side magnifier (crisp zoom — does the residual settle look seamless, any reconfig stutter?).

### Next
- [ ] QUIC lane-splitting (per-frame unidirectional video streams); validate QUIC latency over a real/Tailscale link.
- [ ] Mac→iPhone file transfer; tight A/V lip-sync.
- [ ] Magnifier follow-ups (if on-device testing shows them): tune the residual-settle timing; consider raising encode bitrate when cropped; smooth the crop transition.

### Later
- [ ] M6 polish: adaptive bitrate/fps, reconnect + APNs re-wake, settings, quality HUD. TCC onboarding UI. Device keypairs + revocable PairingStore.

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

## Backlog

### Zoom: viewport should fill the phone's aspect when zoomed (currently keeps the Mac's aspect)
- **Observed (on device):** zooming magnifies but the view stays the Mac's landscape aspect — the letterbox bars persist on the portrait phone even when zoomed in. User expects a zoomed view to fill the phone (portrait crop).
- **Root cause:** the host's SCStream output buffer is a fixed size = display dimensions (`CaptureEngine` `config.width/height` set once at start). `setViewport` only changes `sourceRect`; the crop is then **scaled back up to fill the same display-aspect buffer**, so every encoded frame is landscape. The client (`MetalVideoRenderer`) aspect-FITS a landscape frame into the portrait view → bars never disappear, regardless of zoom or the residual settling to 1.
- **Fix (two-mode, reuses pumpVideo's existing encoder-rebuild-on-dimension-change):**
  - Overview (zoom ≈ 1): `sourceRect` = full, output = display dims, client letterboxes the whole display (today's behavior — keep it).
  - Zoomed (zoom > ~1.05): host sets `config.width/height` to a **view-aspect** resolution (~display res, aspect = the client's view aspect) and crops a **view-aspect** `sourceRect` region; client aspect-fit then FILLS the phone. One encoder rebuild at the overview→zoom transition; keep output dims constant within zoom mode (only `sourceRect` changes) so pan/zoom don't rebuild.
  - Client computes a view-aspect crop (window ∩ display) from `geo.size` aspect; the host can derive output aspect from the crop's normalized pixel-aspect (no extra wire field). Residual math stays uniform since frame+target share the view aspect while zoomed (brief aspect mismatch only at the transition frame).
- **Files:** `Sources/portview-host/CaptureEngine.swift` (setViewport: also set output dims), `Sources/portview-host/PortviewHostApp.swift` (pass/handle), `apps/PortviewClient/Sources/ContentView.swift` (view-aspect target crop + residual), maybe `Viewport` (only if the crop-derived aspect proves insufficient).
- **Acceptance:** zooming in on a portrait phone fills the screen (no bars); zoom-1 still shows the whole display.
- **Verify:** `swift test` green; on-device visual check.
- **Tier hint:** Opus to scope (geometry + capture reconfig + can't be unit-verified); careful on-device iteration.

### Zoom: jerky at large zoom
- **Observed:** panning/zooming at large zoom is jerky.
- **Likely causes:** SCStream `updateConfiguration` (sourceRect) reconfig latency on each throttled viewport send (~12 Hz) during a pan; residual transform stepping between host confirmations; possible keyframe/scene-change cost when the crop jumps.
- **Ideas:** smoother/predictive viewport (lead the pan), interpolate frameViewport on the client between confirmations, lower reconfig rate + lean more on client residual during motion, or raise fps.
- **Tier hint:** Sonnet/Opus; needs on-device profiling.

### Zoom: pixelated at large zoom
- **Observed:** image is pixelated at large zoom.
- **Cause:** the crop is scaled to a constant output resolution; at high zoom the crop's native pixels < output → upscaling. Bitrate (25 Mbps) is also spread over the (now constant-size) frame.
- **Ideas:** encode the crop nearer its native resolution (variable output dims — but watch encoder-rebuild churn vs the jerky issue), and/or raise bitrate when cropped (adaptive). Pairs naturally with the aspect-fill rework above.
- **Tier hint:** Sonnet/Opus; pairs with the aspect rework + adaptive bitrate (M6 polish).

## Constraints

- Apple Silicon only; macOS 26+ / iOS 26+. Swift 6.2 / Xcode 26.
- Mac must be logged in (no pre-login capture / no remote-unlock — hard public-API limit).
- iOS session is foreground-only (background suspends + drops connection; re-wake via push).
- No servers we host; remote is the user's own overlay VPN.
- Permissive license → clean-room only (no GPL refs like Lumen/Moonlight).

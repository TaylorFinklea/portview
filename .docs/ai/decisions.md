# Decisions

> Architecture decision records. Append-only — one entry per decision.

## [2026-06-16] Magnifier: throttle viewport re-crops (track the pan, don't wait for it to stop)

**Context**: Device test — at high zoom, panning didn't repaint until the cursor STOPPED, then took ~1s to settle. The magnifier follows the host cursor, and the crop re-request went through `ViewportRequestScheduler` as an IDLE DEBOUNCE (fired 250ms after the cursor stops). So during continuous motion the host never re-cropped: you panned within the tiny 8% crop padding, ran out of captured pixels, and only saw the new region after stopping + debounce + a keyframe round-trip.

**Decision**: (1) Rewrite `ViewportRequestScheduler` as a LEADING + TRAILING THROTTLE — fire the first request immediately, then at most once per `interval` (150ms) while requests keep arriving, with a trailing fire for the resting position — so the host crop TRACKS the cursor during a pan. Safe to do now (the debounce was added 2026-06-10 to stop `updateConfiguration` stutter) because the discrete-ladder change made pan re-crops cheap: a pan is origin-only → `sourceRect`-only `updateConfiguration`, no encoder rebuild. (2) Widen `ZoomGeometry` crop padding 0.08→0.25 for more local-pan headroom between re-crops. Both knobs tunable.

**Risk to watch (device)**: re-cropping ~6×/s during a pan means ~6 keyframes/s (each applied crop forces one). If that reintroduces stutter, raise the interval or stop forcing a keyframe on pure-pan (origin-only) re-crops — deferred until the device says.

**Verify**: iOS throttle tests (leading-edge synchronous, burst→leading+latest-trailing, reset cancels trailing, near-dup suppressed) green; iOS TEST SUCCEEDED. Reviewed by qwen (tool-enabled). Device-verify: high-zoom pan repaints AS you move, not after you stop.

## [2026-06-16] Magnifier: the viewport travels in the VideoFrame (kill the echo/frame race)

**Context**: After the crash-hardening landed, qwen's adversarial review flagged a MEDIUM: the host told the client which region a frame showed via a SEPARATE `.viewport` echo (sent from the inbound-loop task) while frames were sent from the concurrent `pumpVideo` task — so at a crop change a new-region frame could arrive ~1 frame before its echo → ~16ms misalignment at zoom-rung crossings.

**Decision**: Embed the active region in EVERY `VideoFrame` — 4 normalized `UInt16` fields mirroring `Viewport`'s convention (full-display defaults so old call sites mean "whole display"). `pumpVideo` tags each frame with `capture.currentViewport()`; the client sets `frameViewport` from the frame it is rendering, so region + pixels update atomically (no cross-message ordering race). The standalone `.viewport` echo is removed from the host (the client keeps a harmless, documented fallback handler). The client assignment is change-guarded so a static region doesn't fire `objectWillChange` ~60×/s.

**Residual (honest)**: a 1–2 frame transient at crop changes still exists because SCStream doesn't tell us which delivered buffer corresponds to which `updateConfiguration` — the frame is tagged with the crop active at ENCODE time, which can lead an in-flight (`.bufferingNewest(2)`) buffer by ≤2 frames. This is inherent to SCStream and was present before (plus the now-removed ordering race). If device-test shows a visible blip at rung crossings, tag the buffer at CAPTURE time (a lock-protected rect read in the SCStream callback) — deferred.

**Process**: spec'd by Opus → implemented by a Sonnet subagent (3 gates green) → adversarial review by qwen (tool-enabled) + Opus. qwen's 2 findings (60Hz churn, dead echo case) both applied; its 4 false-positives confirmed the wire encode/decode symmetry, the clamp, the echo removal, and Equatable correct. See `~/.claude/model-scorecard.md` (2026-06-16).

**Verify**: `swift test` 126/36; iOS 38; macOS BUILD SUCCEEDED. Device-verify pending (with the ladder).

## [2026-06-16] Magnifier crash-hardening — discrete capture-size ladder (rapid-zoom de-risk)

**Context**: The 2026-06-15 region-streaming fix landed build-green but unverified, with a known crash landmine: it snapped `config.width/height` to mult-of-16 (~215 distinct sizes on a 3440px display), so a continuous pinch reconfigured the live SCStream + tore down/rebuilt the VideoToolbox encoder on nearly every step — the historical rapid-zoom crash shape. Hunted ultracode-style: a 5-model adversarial audit (haiku, sonnet, minimax-m3, qwen3.7-max, kimi-k2.7-code) → fix → tool-enabled adversarial review of the diff.

**Decision**: Snap the **captured region's size** to a coarse geometric ladder (`CaptureSizing.snapCropFraction`, ratio 0.8 ⇒ ~13 rungs across the zoom range), snapped UP so the captured region still ⊇ the requested window. `setViewport` captures that snapped region (recentered on the request, clamped) and the encoder output is sized from the SAME snapped fractions, so the buffer aspect equals the captured-region aspect exactly (no stretch). The host now ECHOES the snapped region (not the raw request); the client sets `frameViewport` from it so its zoom transform stays aligned. SCStream/encoder reconfigure only at rung crossings (~13 vs ~215) → the rebuild churn that caused the crash is gone, at the cost of crispness stepping in discrete rungs (≤~20% below native; densify the ladder if device-test shows softness).

**Why snap the captured region, not just the output buffer**: the Metal client aspect-fits the *buffer* dims while `ZoomGeometry` computes its transform from the *crop* aspect (`frameViewport`) — so the buffer aspect MUST equal the captured-region aspect or the magnified image misplaces/stretches. Snapping only the output (independent per-axis) would break that; snapping the captured region keeps sourceRect, output buffer, and echo all derived from one snapped fraction.

**Also fixed** (audit findings, verified real): config save/restore on `updateConfiguration` failure (it was mutated before the throwable call → desynced the unchanged-check baseline → could wedge the crop); `encoder = nil` on encode failure (was re-entering a wedged VT session every frame); stale `ZoomGeometry` doc-comment. **Verified-not-bugs** (audit false positives): the "config reference-type *race*" (each connection owns its `CaptureEngine`; the inbound loop *awaits* `setViewport` → no concurrent writer; qwen refuted the related encoder use-after-free) and `.zero` sourceRect (Apple's documented full-display sentinel).

**Adversarial review** (sonnet, tool-enabled, 19 tool uses): PROVED the snap+clamp safety invariant (captured region always ⊇ requested window), idempotency, echo-doesn't-misplace, inbound-loop atomicity; one real LOW (near-full snap seam) fixed by deciding `cropping` off the snapped fractions. Deferred (physically unreachable at ≤~6× max zoom): anisotropic floor stretch when both axes hit the 64px floor.

**Model head-to-head note**: the cheap pi models (qwen3.7-max, minimax-m3) out-accurated the native subagents here — both natives led with the unreachable config-race "critical"; qwen explicitly refuted it. See `~/.claude/model-scorecard.md` (2026-06-16 entries).

**Verify**: package `swift test` 125/36; iOS 38; macOS BUILD SUCCEEDED. **DEVICE-VERIFY still required** — confirm rapid zoom in/out no longer crashes (the whole point), text stays crisp, and zoom feels continuous despite discrete rungs. Spec addendum: `docs/superpowers/specs/2026-06-15-magnifier-region-streaming.md`.

## [2026-06-16] M7 — Host presence & frictionless connect (menu-bar, live permissions, input order)

**Context**: Device testing surfaced pairing/permission friction + choppy input. M7 makes the host pleasant to live with. Driven ultracode-style across phases: a design workflow (4 grounded specs) → implement P1–P3 → an adversarial-review workflow (5 findings, all fixed) → commit.

**P1 Menu-bar host**: a `MenuBarExtra(.window)` scene beside the `WindowGroup` (now `id "main"`), sharing the single `@State HostAppModel`; `MenuBarHostView` = compact status + real QR + copy-URL + connected count + Start/Stop + "Open window" (`@Environment(\.openWindow)`). Dynamic glyph via a pure, tested `HostMenuBar.symbol(...)`. Hosting now **outlives window-close** (removed the `WindowGroup`'s `onDisappear { stop }`) so the menu bar keeps advertising.

**P2 Live permissions onboarding**: `HostAppModel` publishes REAL `screenRecordingGranted` (`CGPreflightScreenCaptureAccess`, no prompt) + `accessibilityGranted` (`AXIsProcessTrusted`), polled every 2s for the **app lifetime** (not window-scoped). Pure tested `PermissionsOnboarding` derives the guided step/title/body/pane + the Screen-Recording-needs-relaunch caveat; `ContentView` shows real badges + a guided banner (Open Settings + Re-check), replacing the old inferred `PermissionStatus`.

**P3 Input serialization**: `OutboundInputPump` — one ordered FIFO lane per connection (queue + wake-signal drain) that **coalesces consecutive pointer-moves** (summed deltas, latest-wins) while keeping discrete events ordered + lossless; bound/unbound at every connection set/clear (run/reconnect/disconnect). Fixes both the down/up ordering and the move-lurch-under-stall (relevant to the reported choppiness).

**P4 SAS 6-digit pairing**: DESIGN ONLY — a cryptographically-sound cert-comparison (SAS) scheme in `docs/superpowers/specs/2026-06-15-sas-pairing-design.md`, **flagged for human security review** before implementation (client-side-only match check, modular bias, unpinned preamble — all enumerated).

**Adversarial review (3-dim, 5/5 confirmed, all fixed)**: (medium) uncoalesced pointer-moves on an unbounded lane → folded into P3's coalescing; (medium) `isRunning` was derived from the `@ObservationIgnored` task, so the menu glyph + Start/Stop went stale when the serve loop ended while ready → made it an **observed stored bool** set in start/stop/self-clear; (3× low, one root) permission monitoring was window-scoped while hosting outlives the window → moved to **app-lifetime** (idempotent start, no window-close stop), fixing the window-close-stop, menu-bar staleness, and multi-window race.

**Verify**: package `swift test` **122/36**; iOS `xcodebuild test` **38**; macOS **BUILD SUCCEEDED**. Device-verify pending: menu-bar QR/connect; live permission flow (grant Accessibility → dot flips ≤2s; Screen Recording → relaunch); smoother drag.

## [2026-06-15] Magnifier = true region streaming (output dims match the crop aspect)

**Context**: High zoom (~5×, needed to read text on a phone) was blurry/distorted vs VNC. Root cause (3440×1440 ultrawide host + portrait iPhone): the host never cropped. `ZoomGeometry.cropRequest` built a normalized SQUARE (`max(visW, visH)`), which for a full-height window = the whole display; and `CaptureEngine.setViewport` only moved `sourceRect` while keeping output dims = full display, so any non-display-aspect crop would STRETCH (hence the square requirement). Net: the client digitally zoomed a full, low-bitrate frame.
**Decision**: Stream the actual region. (1) Client `cropRequest` = the visible window's OWN aspect (not square), padded for pan. (2) Host sets BOTH `sourceRect` AND `config.width/height` to the crop's pixel size (`CaptureSizing.cropOutputSize`: mod-16/even, capped to display-native, min floor) → the region is encoded 1:1, no stretch, full res. (3) Client render computes its aspect-fit from the FRAME's aspect (`frameAspect = (f.width/f.height)·displayAspect`), not the display's.
**Invariant (no regression)**: at zoom 1 the crop is the full display (display-aspect) → `frameAspect == displayAspect` → the math is identical to the prior overview. Only zoom > 1 (the broken path) changes.
**Churn / crash control** — landmine: the 2026-06-04 tight-crop/native-res attempt CRASHED + stretched. Output dims change only when the crop SIZE changes (i.e. zoom), not on pan (panning moves `sourceRect` only → no encoder rebuild); dims are quantized (mod-16) + capped + floored so jitter near a zoom level doesn't thrash `updateConfiguration`/the encoder; the 250 ms viewport debounce + "near-full = no crop" short-circuit stay.
**Tests**: `ZoomGeometryTests` (zoom-1 unchanged + scale 1; high-zoom on ultrawide crops a real region that follows the cursor; settled render finite/zoomed) + `CaptureSizing.cropOutputSize` (even/cap/floor). Build-green: 113 pkg / 36 iOS / macOS builds. **DEVICE-VERIFY REQUIRED** — changing `config.width/height` + `updateConfiguration` on a live SCStream is the historical crash point. Spec: `docs/superpowers/specs/2026-06-15-magnifier-region-streaming.md`.

## [2026-06-15] Three device-testable features: quality controls, endpoint-based persistence, Mac→iPhone files

**Context**: User asked to "burn through real features" they can test on-device. Picked three high-observability ones (ultracode; build-green, device-verify pending).

**1. Quality controls — the host now HONORS the client's requested bitrate/fps.** Found that `serveSession` hardcoded `capture.start(maxFPS: 60)` and the encoder used a width·height heuristic, so the client's `StartSession.targetBitrate`/`maxFPS` were *ignored*. Now `serveSession` captures them (clamped via the new `StreamParameters`: fps 10–60, bitrate 2–120 Mbps; 0 = "unset" → fps 60 / heuristic) and threads them into `pumpVideo` (`capture.start(maxFPS:)` + `VideoEncoder(averageBitRate:)`), reused across display switches. Client: `ClientSettings` (persisted bitrate 4–80 Mbps + fps 30/60) read at handshake time via `ClientSettings.load()` instead of the old hardcoded 25 Mbps/60; a Glass **Settings** sheet (gear on Deck Home) edits them + "Forget all saved Macs" + version. This is the real knob for the long-running crispness investigation (raise bitrate → HUD shows it → crisper). Decided client-reads-UserDefaults-at-handshake over injecting a settings object (decoupled; applies next connect).

**2. Resolved-endpoint persistence — unified, replacing `PairingCoordinator`.** `PortviewConnection.resolvedRemoteEndpoint` (`currentPath?.remoteEndpoint`) exposes the live concrete `host:port`. On first stream, `SessionViewModel` publishes `connectedHostToSave` (name + resolved IP + pin) for ALL paths; `ContentView` persists it. This fixes the two deferred items at once: discovered (Bonjour `.service`) pairings now persist with a concrete IP (review #2 from the Glass batch), and a moved saved Mac's IP refreshes in place. `SavedHostsStore.upserting` matches **name → host:port → pinHex** (the pinned cert is the stable per-Mac identity, so a manual-IP entry and a later Bonjour entry for the same Mac fold into one rather than duplicating). Retired `PairingCoordinator` (+ its test) — the resolved-endpoint signal supersedes the markPending/commit dance.

**3. Mac→iPhone file transfer (completes M5 both directions).** Host "Send a file" card → `NSOpenPanel` → `HostControl.sendFile(…, to: sessionID)` streams `FileOffer`+64 KB `FileChunk`s over the active connection. Client `IncomingFileTransfers` **streams each chunk straight to disk** (a per-transfer UUID temp dir), never buffering the whole file (bounded iPhone memory), then publishes a `ReceivedFile` the UI offers via `ShareLink`.

**Security + adversarial review.** Automated security pass flagged **path traversal** — the host-supplied filename was joined into a temp path; now sanitized to a safe last-path-component at offer time (`..`/`.`/empty rejected), TDD'd. A 3-dimension review found 6 (all confirmed, all fixed): the in-memory-buffering OOM risk (→ stream to disk, MEDIUM), partial-transfer state not reset across reconnect (→ reset at each `streamSession` start), nondeterministic multi-client send target (→ target by `sessionID`), manual-vs-Bonjour duplicate (→ pin tiebreaker), temp-file aliasing (→ per-transfer dir), and disconnect dropping an in-hand received file (→ clear `receivedFile` on `start()` not `disconnect()`, so it survives a disconnect for sharing).

**Verify**: package `swift test` 110/34; iOS `xcodebuild test` 31/31; macOS BUILD SUCCEEDED. Device-verify pending (see roadmap Now): the quality knob's visible effect, discovered-Mac persistence across relaunch, IP refresh after a move, and a round-trip file send.

## [2026-06-15] Glass HUD visual direction across both apps (design handoff)

**Context**: A claude.ai/design handoff (`design_handoff_portview_glass_hud`, fetched as a gzip bundle from the share URL) locked the "Glass HUD" look — 6 iOS screens + 3 macOS host states — to recreate in the existing SwiftUI, wired to real types (no parallel state). User chose "build everything" (incl. the two states needing new model surface) + System fonts.
**Decision**: Per-app `GlassTheme.swift` (the two apps are separate XcodeGen targets; the SwiftPM core has no SwiftUI, so the token language is duplicated, not shared). Glass = `Material`/`.ultraThinMaterial` + dark tint + border/inset (README asked for Material, NOT iOS-26 Liquid Glass `glassEffect`). **Fonts: System SF (grotesque) + SF Mono (all numeric telemetry)** — the README explicitly blesses already-licensed equivalents; chosen over bundling Schibsted Grotesk/JetBrains Mono to avoid committing font binaries. Kept the real critically-damped cursor-follow spring (response 0.1 / damping 1.0). Real QR on the host via CoreImage `CIQRCodeGenerator` + `falseColor` tint (signal-on-dark).
**No fabricated data** (the hard rule): the quality panel/rail surface **real** `QualityDiagnostics` — link Mbps, fps, decode ms, encode ms. The mock's hero "LATENCY 42 ms" is **omitted**, not faked — RTT is measured nowhere in the app (a pong-timestamp metric is a possible follow-up). The host activity log filters CLI-only multi-line artifacts (ASCII box + terminal QR) rather than inventing timestamps. Host "Sharing Display" card is static (display switch is client-driven; the host model has no picker).
**Two states needed new (real) model surface, built rather than faked**:
- **iOS `.reconnecting`** — new `SessionViewModel.Status` case + bounded mid-session re-bind: on a mid-stream drop (not a user `disconnect()`), spin a `PortviewBrowser`, rebuild candidates (Bonjour-by-name first, then the endpoint that worked — `reconnectCandidates`, unit-tested), retry the pinned handshake within a 30 s window. `rediscover` uses a `withTaskGroup` browse+timeout race with `browser.stop()` to terminate the browse task (no deadlock). Orchestration is build-green / device-verify-pending (repo house style — run-loop mock tests stay YAGNI; the pure candidate logic is unit-tested).
- **macOS "device connected" (state C)** — `HostRunner.serveSession` now `emit`s `.deviceConnected(name from ClientHello)` / `.deviceDisconnected` / `.sessionStats` (throughput/fps/encode from the existing `QualityStatsAccumulator` + display dims). A pure `HostSessions` reducer (unit-tested) folds these; `HostAppModel` exposes the derived state + `connectedSince`. A `HostControl` (NSLock registry) backs a **real Disconnect that keeps the listener advertising** (no port churn).
**Adversarial review (4-dimension workflow, 9/9 confirmed real)** — fixed: (1, high) host Disconnect sent a bare close that the client's new auto-reconnect undid → host now sends `.bye` first; client treats `.bye` as a deliberate terminal close (`.evicted`), only a bare drop re-binds; (3) `sendClick()` down+up now share one Task so they can't invert into a stuck click; (6) live toolbar reordered to gauge→keyboard→paste→file per spec; (7/8) host "connected mm:ss" now ticks via `TimelineView` (was reading `Date()` with no clock); (9) per-connection **UUID** session identity so a stale disconnect during reconnect can't evict the live session. Deferred: (2) persisting a *discovery-paired* Mac needs the resolved remote endpoint — same blocker as the existing "refresh saved fallback IP" follow-up; not a regression (matches prior behavior). No-action: (4) LINK promoted to the signal hero after LATENCY's removal (reviewer: the better choice); (5) static Sharing-Display card (honest — no host picker).
**Verify**: package `swift test` 104/33; iOS `xcodebuild test` 17/17; macOS `xcodebuild` BUILD SUCCEEDED; CLI builds. Device-verify pending: live reconnect on a real IP change, host state C with a real connected device, the Glass look on-device.

## [2026-06-02] Own Mac host agent (not built-in-server interop)

**Context**: iPhone→Mac screen sharing today means VNC, which feels laggy. Mac-to-Mac feels native.
**Decision**: Ship our own open-source Mac host agent that captures + encodes; do NOT interop with macOS's built-in Screen Sharing server.
**Alternatives considered**: (A) interop with built-in server (zero install); (C) both.
**Rationale**: Apple's fast Mac-to-Mac path ("High Performance" UDP + private MVS RFB encodings) is proprietary, Apple-silicon-only, undocumented. A third-party client to the built-in server is stuck on the slow raw/zlib framebuffer path = VNC lag. Owning the host (ScreenCaptureKit + VideoToolbox, both fully public) is the only route to native feel, and keeps us fully open-source. Validated by 70-agent research workflow.

## [2026-06-02] LAN-direct, overlay-friendly connectivity (no servers)

**Context**: Need to reach the Mac from the iPhone.
**Decision**: Direct connection — Bonjour discovery on LAN; remote works over the user's own Tailscale/WireGuard.
**Alternatives considered**: LAN-only; full internet with our own rendezvous/TURN relay + accounts.
**Rationale**: Zero infra to host; a Tailscale endpoint looks like a remote host and "just works." User already runs Tailscale. App Store 4.2.7 fits cleanly (LAN/own-device mirror). True serverless internet P2P is impossible anyway (always needs a rendezvous point) — delegate to the overlay VPN.

## [2026-06-02] Trackpad-style input

**Decision**: iPhone surface acts as a trackpad (relative cursor, tap-click, two-finger scroll). Direct-touch is a later mode.
**Rationale**: Precise control of a full desktop on a small screen without finger occlusion. Matches Jump Desktop/Screens defaults.

## [2026-06-02] Custom protocol over QUIC; hardware HEVC

**Context**: Transport choice drives both latency and license.
**Decision**: Custom protocol over QUIC (Network.framework), hardware HEVC encode (H.264 fallback). Six logical lanes; video/audio push with drop-stale.
**Alternatives considered**: WebRTC (libwebrtc); fork Lumen/Moonlight GameStream.
**Rationale**: We don't need WebRTC's NAT traversal (LAN/Tailscale = direct), so its weight is wasted; QUIC gives TLS 1.3 + multiplexing + good loss behavior with zero deps. Zero deps → permissive Apache-2.0 (Lumen/Moonlight are GPLv3). Most "native" and on-ethos.

## [2026-06-02] POC transport = TLS-over-TCP (QUIC remains the production target)

**Context**: Implementing PortviewTransport. QUIC datagrams + options verified in the macOS 26 SDK, and a one-way QUIC loopback (TLS identity + handshake + framed message) passes. But the *bidirectional* model using a bare `NWConnection(to:using:quic)` client + `NWListener.newConnectionHandler` double-delivers connections (QUIC connection-level + stream-level) and the server's reply-send hangs — correct QUIC multiplexing needs the `NWConnectionGroup`/`NWMultiplexGroup` model, which has a chicken-and-egg (group not `.ready` until a stream opens; stream open returns nil before ready).
**Decision**: Ship the POC over **TLS-over-TCP** (`TLSParameters`): one unambiguously-bidirectional connection. Keep `QUICParameters` + the passing QUIC loopback spike as proven groundwork. `PortviewConnection` is transport-agnostic (it just send/receives framed bytes over an `NWConnection`), so reverting to QUIC is a one-line `NWParameters` swap.
**Alternatives considered**: keep fighting the QUIC multiplex-group API now; two QUIC connections (one per direction); fall back fully to TCP and drop QUIC.
**Rationale**: Don't let QUIC stream-multiplexing intricacy block proving the actual product (live screen on a remote device). On localhost/LAN, TCP vs QUIC is invisible for a POC. QUIC's loss-resilience/HoL-avoidance benefits are a native-feel optimization for lossy links (M6), behind the same transport boundary. Certificate pinning + TLS 1.3 are identical on both paths, so the security model carries over unchanged.

## [2026-06-02] Bleeding-edge OS only (macOS 26 / iOS 26, Apple Silicon)

**Decision**: Target only current OS; no legacy fallbacks.
**Rationale**: Unlocks newest ScreenCaptureKit, Core Audio process taps, VideoToolbox HEVC low-latency, modern NetworkConnection QUIC API, Swift 6 concurrency. Simpler, higher-quality build. User runs current devices.

## [2026-06-02] Name "Portview", license Apache-2.0

**Decision**: Project name **Portview** (renamed 2026-06-02 from the original "Porthole"); license **Apache-2.0**.
**Rationale**: "Porthole" felt off; "Portview" reads cleaner and stays on-theme — a view through a port to your Mac. Rename was a mechanical sweep (modules, targets, types, bundle id `dev.finklea.portview`, Bonjour `_portview._tcp`, `portview://` pairing scheme, dirs, docs). Apache-2.0 = permissive + explicit patent grant (safer than MIT for a project implementing a network protocol and touching codecs).

## [2026-06-02] QUIC multiplex (NWMultiplexGroup) scaffolded; TLS-over-TCP still ships

**Context**: Revisiting the deferred QUIC transport (M6). Added the `NWConnectionGroup`/`NWMultiplexGroup` model as an additive, opt-in path (`PortviewConnection.connectQUIC`, `PortviewListener(quicIdentity:)`), keeping TLS-over-TCP as the default — zero regression risk. A loopback bidirectional test (`QUICMultiplexTests`) was written as the arbiter.
**Decision**: Keep the QUIC multiplex scaffolding + cancellable `awaitReady`; leave TLS-over-TCP as the shipping transport. The QUIC loopback test is `@Test(.disabled(...))` (documents the blocker without breaking the suite).
**Finding (reproduced cleanly)**: the documented chicken-and-egg is real, from both sides — (a) awaiting the group's `.ready` *before* opening a stream hangs (the group never reaches `.ready` on its own, and that continuation is un-cancellable, so it deadlocks the whole task — fixed `awaitReady` to be cancellable so this can't hang again); (b) calling `NWConnection(from: group)` *immediately* after `group.start()` returns nil (`streamUnavailable` — the group can't vend a stream yet). So neither "ready-then-open" nor "open-immediately" works as written.
**Next (when resumed)**: candidate fixes — dispatch the stream-open onto the group's queue *after* start so the group has processed `start` before vending; or set the group's `newConnectionHandler` and drive readiness differently. Best nailed with on-device validation + closer reading of Apple's QUIC `NWConnectionGroup` sample; do NOT swap the default until the loopback bidirectional test passes.
**Rationale**: Per the additive-behind-a-flag plan: real, committed groundwork on the exact blocker without risking the hardware-verified TLS path. Stopped short of permuting the finicky API blind (the "don't keep fighting the multiplex API now" alternative the prior session rightly rejected) rather than ship confidently-wrong networking code.

## [2026-06-02] QUIC is now the DEFAULT transport (bare NWConnection, no multiplex group)

**Context**: User asked to actually switch to QUIC. Ran an empirical sweep — 6 candidate choreographies, each in an isolated worktree running a real loopback bidirectional round-trip with hang detection.
**Breakthrough**: the `NWConnectionGroup`/`NWMultiplexGroup` model was a RED HERRING. A **bare `NWConnection(to:using:QUICParameters.client)` is itself one bidirectional QUIC stream**, and it completes a full bidirectional round-trip (~0.14s, no group). The prior "chicken-and-egg" only existed because we were using the group API at all.
**The real gotcha (and fix)**: QUIC's `NWListener.newConnectionHandler` genuinely DOUBLE-DELIVERS — it fires twice per client: a count=1 "control" connection that only ever yields "Socket is not connected"/isComplete, then count=2 which carries the actual ClientHello. The prior session's "reply hangs" was almost certainly replying on the dead control connection. Fix: the host serves each accepted connection CONCURRENTLY (`Task { await serve(...) }`), so the dead one self-terminates without starving the live one; only the data-carrying connection runs a session. (Corroborated by both the BareBidi and ServerDedupe sweep candidates.)
**Decision**: QUIC is the default — client uses `PortviewConnection.connectQUIC`, host uses `PortviewListener(quicIdentity:)` + concurrent serve. Removed the dead multiplex scaffolding (`NWConnectionGroup`/`NWMultiplexGroup`, `QUICError`, the retained `group`). Kept `awaitReady` cancellable. TLS-over-TCP (`connect`/`PortviewListener(identity:)`) stays available as a one-call fallback. Bonjour service type changed `_portview._tcp` → `_portview._udp` (QUIC is UDP; client NSBonjourServices updated to match — iOS denies browsing undeclared types). The `QUICBidirectionalTests` loopback test is now ENABLED and green (real PortviewConnection/PortviewListener round-trip). Full suite 70/25; host + iOS build clean.
**Next**: lane-splitting (per-frame unidirectional video streams) remains future work; needs on-device validation over a real/Tailscale link to confirm latency wins.

## [2026-06-14] Saved-Mac reconnect survives LAN IP changes via Bonjour name-rediscovery

**Context**: With stable pin+port (2026-06-13), a saved Mac still failed to reconnect after its LAN IP changed (DHCP) — the client only tried the stale saved `host:port`. Client-only follow-up.
**Decision**: At saved-Mac reconnect, build ordered connection candidates — a live Bonjour host **matching by name** first (its `.service` `NWEndpoint` re-resolves to the current address), then the saved `host:port`. `SessionViewModel.run` tries candidates until the **pinned** QUIC handshake succeeds (initial connect only — a mid-stream drop never re-targets). The saved **pin is unchanged**, so cert pinning gates every candidate; the Bonjour name is only a routing hint (a same-name impostor can't present the pinned cert). Discovery already runs on the connect screen, and `DiscoveredHost.name == SavedHost.name` (both the Mac's Bonjour name), so the join is by name.
**Alternatives**: saved-IP-first then Bonjour-on-failure (eats a connect-timeout on the exact case we're fixing); re-resolve + rewrite the saved IP (needs the resolved address off the connection — deferred, see below).
**Rationale**: Off-LAN uses the saved IP (Tailscale IPs are stable per device); on-LAN, name-rediscovery makes reconnect robust to IP churn. Strictly better than before (reconnect used to just fail).
**Deliberately deferred (review-flagged)**: after a Bonjour reconnect to a new IP, the saved entry keeps the OLD IP (re-saved as-is by `PairingCoordinator`). Not a regression — on-LAN rediscovery works every time by name regardless; the stale IP is only the off-LAN fallback. Refreshing it needs `PortviewConnection` to expose the resolved remote endpoint (a transport API change, out of this client-only scope). Tracked as a roadmap follow-up.
**Adversarial review**: 3-dimension / 8-confirmed pass. Rejected: the "cancellation regression" (cancellers own status; new loop reduces a pre-existing disconnect race) and run-loop mock-tests (would need a connection-injection seam for trivial loop mechanics; ordering is unit-tested). Accepted: manual-IP-name fallback + duplicate-name single-endpoint tests.

## [2026-06-13] Persist host identity as a Keychain p12 blob; stable port; app/CLI separation

**Context**: Saved pairings broke on every host restart — the host minted a fresh self-signed cert (new pin) and `NWListener` bound an ephemeral port each launch, so the client's pinned cert + saved `host:port` no longer matched. Roadmap item was "persist identity in Keychain"; the *purpose* ("saved pairings survive restarts") also requires a stable port.
**Decision**: Persist the existing openssl-minted **PKCS#12 blob + the bound port as ONE Keychain generic-password item** (`kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), re-imported each launch. Bump cert validity `-days 2`→3650, re-mint when <30 days remain. Add an optional `port:` to `PortviewListener` (`NWListener(using:on:)`), preferred-then-ephemeral-fallback in `HostRunner`. Host-only; no client change.
**Alternatives considered**: (B) store a first-class `kSecClassIdentity` — `SecPKCS12Import` already touches the keychain, identity-ACLs are brittle for the unsigned `swift run` CLI, querying-by-label is fiddly; (C) replace openssl with a native `SecKey` cert generator — out of scope; client Bonjour re-resolve to float the port — LAN-only (breaks Tailscale) + client complexity.
**Rationale**: Reuses the entire tested mint path; the blob's protection is the keychain ACL (the hardcoded p12 passphrase is irrelevant). One item = atomic identity+port lifecycle.
**Review-driven specifics** (15-finding adversarial review):
- **App vs CLI use DISTINCT service strings** (`…host.identity` vs `…host.identity.cli`). A single shared item let the unsigned CLI churn the signed app's pin (different code-signature ACLs → the CLI can't read the app's item, mints its own, breaking the supported app's pairing). The app is the supported restart-surviving path; the CLI is a dev fallback.
- Non-persistence + port-fallback are surfaced via `HostRunnerEvent.message` (no silent degradation).
- `errSecDuplicateItem` on the add-race retries as update; the partially-started listener is cancelled before fallback; a process lock serializes the read-mint-write critical section.
**Deliberately rejected review findings**: (a) reading the cert's real validity via `SecCertificateCopyValues` — the stored `notAfter` is computed from the *same mint moment* as the cert, so it can't diverge except by clock manipulation, and a corrupt blob is already caught by `importPKCS12`→re-mint; (b) explicit corrupted-record deletion — `write` does update-first, so a fresh mint overwrites a corrupt record automatically (self-heals; proven by a test).
**Not addressed (follow-up)**: IP stability — `SavedHost.host` is a DHCP-able LAN IP; a change still breaks reconnect even with stable pin+port (Bonjour rediscovery / stable Tailscale IP covers it).

## [2026-06-05] ScreenCaptureKit capture output uses filter point-pixel scale

**Context**: Video quality HUD showed zoomed iPhone sessions still soft. First device HUD: full-frame `1710x1107`, no crop, tiny actual bitrate. A CoreGraphics backing-pixel attempt made the crop move on device, but the second HUD still showed `Enc 1710x1107`, so that route did not change ScreenCaptureKit output.
**Decision**: Size `SCStreamConfiguration.width/height` from `SCDisplay.width/height * SCContentFilter.pointPixelScale`. Keep `SCStreamConfiguration.sourceRect` in the display point coordinate system.
**Rationale**: macOS 26 SDK headers define `SCDisplay.width/height` as points and expose `SCContentFilter.pointPixelScale` for the capture filter. `CGDisplayPixelsWide/High` is not the right source of truth for this stream sizing path.

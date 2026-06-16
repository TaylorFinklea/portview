# Spec: Magnifier region-streaming (high-zoom crispness)

**Status:** in progress (2026-06-15). Build-green target; device-verify each step with the user.

## Problem
At the zoom needed to read text on a phone (~5×), the image is blurry/distorted vs VNC. On a
3440×1440 ultrawide host + portrait iPhone, the host **never crops**: `ZoomGeometry.cropRequest`
builds a normalized SQUARE (`side = max(visW, visH)`), and the visible window is full-height
(`windowH = (1/ratio)/z ≈ 1.0` until zoom > displayAspect/viewAspect ≈ 5.2), so `side = 1.0` = the
whole display. The client then digitally zooms into a full 3440×1440 frame encoded at ~1.3 Mbps.

The square requirement exists because `CaptureEngine.setViewport` changes `sourceRect` only and keeps
`config.width/height` = full display dims — a non-display-aspect crop would be **stretched** to fill
the output buffer.

## Fix — stream the actual region (like VNC)
1. **Client crop request** = the actual visible window (any aspect), padded for pan headroom, clamped
   to [0,1]. NOT a square. Size is determined by zoom (stable across pans → output dims stable per
   zoom); only the origin moves while panning.
2. **Host output matches the crop aspect.** `setViewport` sets `config.sourceRect` to the crop AND
   `config.width/height` to the crop's pixel size (even, capped to display-native, min floor) so the
   region is encoded 1:1 — full res, no stretch. The encoder (in `pumpVideo`) already rebuilds when
   the buffer dims change.
3. **Client render uses the FRAME's aspect.** `ZoomGeometry` computes its aspect-fit `videoSize` from
   `frameAspect = (f.width/f.height) * displayAspect` (where `f = frameViewport`) instead of
   `displayAspect`. Everything else (window→videoRect mapping, renderScale, pan) is unchanged.

### Invariant preserved (no regression)
At zoom 1: window ⊇ display → cropRequest ≈ full → host no-crop → frame = full display
(display-aspect) → `frameAspect == displayAspect` → new math == old math. The change only affects
zoom > 1, which is the currently-broken path.

## Churn / crash control (landmine: the 2026-06-04 tight-crop attempt CRASHED + stretched)
- Output dims change **only when the crop size changes** (i.e., on zoom, not pan) — panning moves
  `sourceRect` origin only, so most updates are sourceRect-only (cheap, no encoder rebuild).
- **Quantize** output dims (even / mod-N) + cap to display-native + a min floor, so sub-step jitter
  near a zoom level doesn't thrash `updateConfiguration` / the encoder. `CaptureSizing` gets a pure,
  unit-tested `cropOutputSize(...)`.
- Keep the existing 250 ms viewport debounce + the "near-full = no crop" short-circuit.

## Tests
- `ZoomGeometry` (pure, unit): zoom-1 transform unchanged; high-zoom on an ultrawide produces a
  non-full `cropRequest`; the window maps to fill the view; render uses frame aspect.
- `CaptureSizing.cropOutputSize`: even, capped to native, min floor, stable under tiny deltas.
- Host `setViewport` output-resize path: build-green (SCStream needs a device); manual device test.

## Hardening addendum (2026-06-16 — crash-landmine de-risk, pre-device)

A 5-model adversarial audit (haiku, sonnet, minimax-m3, qwen3.7-max, kimi-k2.7-code) of the landed
region-streaming code converged on the rapid-zoom crash cause and surfaced real latent bugs. Fixes:

1. **Discrete output-size ladder (the headline).** `CaptureSizing.cropOutputSize` previously snapped
   each dimension to a mult-of-16 → ~215 distinct widths on a 3440px display, so a continuous pinch
   tore down + rebuilt the VideoToolbox session and called `updateConfiguration` on nearly every
   step (the #1 instability). Now the output resolution snaps to a small **geometric ladder**
   (`ratio 0.8`, ~a dozen rungs across the full zoom range) applied to the crop's *varying* ("driver")
   axis, with the other axis derived by the **same scale** so the crop **aspect is preserved exactly**
   (kills the stretch finding flagged by qwen/minimax/kimi). Snapped **down** (never upscales past the
   crop's native pixels → can't exceed the display → no cap-induced stretch), floored, even. Across a
   pinch the size changes only a handful of times → minimal `updateConfiguration`/encoder churn.
   Tradeoff: the pinned axis (e.g. full height on an ultrawide portrait slice) is encoded ≤20% below
   native at rung boundaries — acceptable vs. a crash; densify rungs if device-test shows softness.
2. **Config save/restore on `updateConfiguration` failure** (`setViewport`). `config` (a reference
   type) was mutated *before* the throwable call; on failure the unchanged-check baseline desynced
   from the live stream → could wedge on the old crop. Now we snapshot sourceRect/width/height and
   restore them if `updateConfiguration` throws, so `config` always reflects the last *applied* state.
3. **Invalidate a wedged encoder** (`pumpVideo`). `catch` set `needsKeyframe = true` but kept the dead
   `VideoEncoder`, so a wedged VT session would spin at frame rate. Now encode failure sets
   `encoder = nil` → next frame rebuilds from scratch (the startup path).
4. **Stale doc-comment** in `ZoomGeometry` (said cropRequest "MUST be display-aspect/square") corrected
   to describe the shipped non-square region-streaming behavior.

**Verified-not-a-bug (audit false positives):** the "config reference-type *race*" (each connection
owns its `CaptureEngine`; the inbound loop *awaits* `setViewport` → no concurrent writer; qwen also
correctly refuted the related encoder use-after-free) and `.zero` sourceRect (Apple's documented
full-display sentinel). Deferred low-priority follow-ups: near-full 0.99 hysteresis, server-side
sourceRect clamp, transitional-frame settle-guard (the ladder already cuts the double-rebuild qwen
flagged). New/updated tests: `CaptureSizingTests` (ladder discreteness, aspect preservation, monotonic,
cap, floor, even).

## Device test plan (with the user)
1. Auto/80 bitrate, reconnect, zoom to ~5× on the ultrawide → text should be **crisp** (region
   encoded at native, not digital-zoom blur). HUD `DISPLAY`/encoder dims should reflect the crop.
2. Pan at high zoom → smooth, no per-pan stutter (output dims stable; only sourceRect moves).
3. Zoom out to 1 → overview unchanged.
4. Watch for any crash on rapid zoom in/out (the historical failure mode).

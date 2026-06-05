# Video Quality Diagnostics Design

Status: approved 2026-06-05.

## Goal

Expose enough live evidence to explain why zoomed Portview video is still soft: host encoder settings, actual encoded throughput, frame rate, encode/decode cost, active crop, client zoom/render scale, and final sampler mode.

## Problem

The current stream can look better after the bitrate increase but still softer than VNC on real device. The host does not tell the client what bitrate it actually configured, how many bits per pixel are being delivered, how often the crop changes, or how long encode takes. The client does not show delivered Mbps/fps/decode time, and the renderer always uses linear sampling, so we cannot distinguish codec softness from final texture filtering.

## Approach

Add a lightweight diagnostics path that is always available during development and cheap enough to leave in the app:

- Host emits a `QualityStats` message about once per second on the existing control connection.
- Client computes complementary receive/decode/render stats from incoming `VideoFrame`s.
- Streaming UI gets a compact Quality HUD toggled from the toolbar.
- Renderer gets a nearest/linear sampler toggle for A/B testing softness.

No adaptive tuning is included in this phase. The output of this phase determines the next fix.

## Data

`QualityStats` carries:

- host encoder dimensions
- configured bitrate
- recent encoded Mbps
- recent fps
- average encoded bytes per frame
- keyframe count
- average encode milliseconds
- active viewport/crop

Client-side stats add:

- received Mbps
- received fps
- bits per pixel per frame
- average decode milliseconds
- latest frame dimensions
- zoom
- render scale
- frame viewport
- sampler mode

## UI

In the streaming toolbar:

- add a gauge button to show/hide the HUD
- add a sampler button while the HUD is visible, toggling linear/nearest

The HUD is an overlay near the top, compact and monospaced enough for device testing. It must not block the main trackpad surface more than necessary.

## Verification

- Protocol round-trip tests for `QualityStats`.
- Metrics accumulator tests for host/client calculations where pure Swift is practical.
- Full Swift package test suite.
- iOS client build.

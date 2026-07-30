# Video Quality Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add live diagnostics that explain remaining zoom softness before tuning codec or render behavior.

**Architecture:** Add a pure protocol message for host quality stats, a host-side rolling accumulator emitted once per second, a client-side rolling accumulator, and a compact SwiftUI HUD. Keep changes additive and avoid changing encoder quality behavior in this phase except for a render sampler A/B toggle.

**Tech Stack:** Swift 6.2, Swift Testing, ScreenCaptureKit, VideoToolbox, Network.framework, SwiftUI, Metal.

---

## Files

- Modify `Sources/PortviewProtocol/MessageType.swift` to reserve the stats message tag.
- Modify `Sources/PortviewProtocol/AnyMessage.swift` and `Sources/PortviewProtocol/Frame.swift` for encoding/decoding.
- Create `Sources/PortviewProtocol/Messages/QualityStats.swift`.
- Add tests in `Tests/PortviewProtocolTests/QualityStatsTests.swift`.
- Create `Sources/portview-host/QualityStatsAccumulator.swift`.
- Modify `Sources/portview-host/CaptureEngine.swift` to expose the active normalized viewport.
- Modify `Sources/portview-host/PortviewHostApp.swift` to record and emit host stats.
- Create `apps/PortviewClient/Sources/QualityDiagnostics.swift`.
- Modify `apps/PortviewClient/Sources/SessionViewModel.swift` to compute client stats.
- Modify `apps/PortviewClient/Sources/MetalVideoRenderer.swift` for sampler switching.
- Modify `apps/PortviewClient/Sources/ContentView.swift` to add the HUD and toggles.
- Update `.docs/ai/current-state.md` and `.docs/ai/roadmap.md`.

## Tasks

- [ ] Add `QualityStats` protocol tests and message implementation.
- [ ] Add host stats accumulator tests where pure Swift, then host emission.
- [ ] Add client diagnostics model and HUD.
- [ ] Add Metal linear/nearest sampler switch.
- [ ] Run `swift test --package-path <repo>`.
- [ ] Generate/build the iOS client project.
- [ ] Update handoff docs and commit.

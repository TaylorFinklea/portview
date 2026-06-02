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

- Toolchain: Swift 6.2, Xcode 26.0.1, macOS 26.3.1 (Apple Silicon). Confirmed.
- `PortholeProtocol` package: builds clean, `swift test` = 31/31 green (9 suites). Wire protocol complete — binary primitives, 6 M0 messages, self-delimiting framing, FrameDecoder stream reassembly, client/server handshake state machines, e2e handshake-over-frames.
- Plan: `docs/superpowers/plans/2026-06-02-porthole-protocol.md` (executed).
- Next: `PortholeTransport` (QUIC over Network.framework) — needs its own plan.

## Blockers

- None.

## Open questions (resolve in M0)

- iOS 26 QUIC: unreliable DATAGRAM frames available? (decides video/audio lane mapping)
- `EnableLowLatencyRateControl` covers HEVC on macOS 26? (else pin H.264 for low-latency path)

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
- `PortholeProtocol` package: builds clean, `swift test` = 31/31 green (9 suites). Wire protocol complete — binary primitives, 6 M0 messages, self-delimiting framing, FrameDecoder stream reassembly, client/server handshake state machines, e2e handshake-over-frames. (Plan: `docs/superpowers/plans/2026-06-02-porthole-protocol.md`, executed.)
- `PortholeTransport`: IMPLEMENTED. 36 tests / 13 suites all green. TLS identity (RSA self-signed via openssl→PKCS#12→SecPKCS12Import), QUIC loopback spike (one-way, proves QUIC works), cert pinning (SHA-256 of leaf DER), MessageChannel, and `PortholeConnection`/`PortholeListener` carrying the full handshake + a VideoFrame over a real localhost connection.
- **POC transport = TLS-over-TCP** (see decisions.md): bidirectional, unambiguous; QUIC's bare-NWConnection+listener model double-delivers connections and the reply-send hangs (needs the NWConnectionGroup/NWMultiplexGroup multiplex model, deferred). PortholeConnection is transport-agnostic, so swapping back to QUIC is one line. QUICParameters + the QUIC loopback spike remain as proven groundwork.
- `PortholeMedia`: IMPLEMENTED + the **core pipeline POC passes**. VideoToolbox hardware HEVC encode + decode (synthetic-frame round-trip recovers color), HEVC sample serialization (parameter sets + AVCC data ↔ bytes), and a full end-to-end test: frame → encode → serialize → VideoFrame over pinned-TLS PortholeConnection → deserialize → decode → color verified. All autonomous (no TCC/GUI).
- **POC STATUS: the entire core pipeline (encode → secure transport → decode) is proven by tests.** Remaining for a watchable demo (need your hardware): real screen capture (ScreenCaptureKit + Screen-Recording grant), on-screen render (Metal/CAMetalLayer), and packaging the macOS host + iOS client apps (Xcode + device).
- Next: host `CaptureEngine` (SCStream) → wire to VideoEncoder; client `MetalRenderer` (CAMetalLayer) for decoded buffers; then the two app targets. These are the hardware/permission-gated pieces.

## Blockers

- None.

## Verified SDK facts (macOS 26.0 SDK, by reading headers)

- QUIC datagrams ARE supported in Network.framework (`NWProtocolQUIC.Options.maxDatagramFrameSize`/`.isDatagram`/`.usableDatagramFrameSize`; `nw_quic_*` in quic_options.h). BUT: only one datagram flow per connection and frames are MTU-bounded (~1200 B) << a video keyframe. → v1 video lane = one short-lived **unidirectional QUIC stream per frame** (no cross-frame HoL; abandon stale via reset). Datagrams reserved as a future sub-frame optimization.
- Two QUIC API generations exist: classic `NWConnection`/`NWListener` + `NWProtocolQUIC.Options` (chosen for v1 — stable, documented) and the new Swift-first `NetworkConnection`/`NetworkListener` + `QUIC`/`QUICDatagram` builders (future swap, insulated behind our own transport types).

## Open questions (resolve during build)

- ~~iOS 26 QUIC datagrams?~~ RESOLVED: supported; not used in v1 (see above).
- Exact `SecIdentity` self-signed creation + `NWMultiplexGroup` stream-open signatures on macOS 26 → verify in transport Task 1 spike (do not prescribe from memory).
- `EnableLowLatencyRateControl` covers HEVC on macOS 26? (else pin H.264 for low-latency path) — resolve when building the host encoder.

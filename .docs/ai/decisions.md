# Decisions

> Architecture decision records. Append-only — one entry per decision.

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

**Context**: Implementing PortholeTransport. QUIC datagrams + options verified in the macOS 26 SDK, and a one-way QUIC loopback (TLS identity + handshake + framed message) passes. But the *bidirectional* model using a bare `NWConnection(to:using:quic)` client + `NWListener.newConnectionHandler` double-delivers connections (QUIC connection-level + stream-level) and the server's reply-send hangs — correct QUIC multiplexing needs the `NWConnectionGroup`/`NWMultiplexGroup` model, which has a chicken-and-egg (group not `.ready` until a stream opens; stream open returns nil before ready).
**Decision**: Ship the POC over **TLS-over-TCP** (`TLSParameters`): one unambiguously-bidirectional connection. Keep `QUICParameters` + the passing QUIC loopback spike as proven groundwork. `PortholeConnection` is transport-agnostic (it just send/receives framed bytes over an `NWConnection`), so reverting to QUIC is a one-line `NWParameters` swap.
**Alternatives considered**: keep fighting the QUIC multiplex-group API now; two QUIC connections (one per direction); fall back fully to TCP and drop QUIC.
**Rationale**: Don't let QUIC stream-multiplexing intricacy block proving the actual product (live screen on a remote device). On localhost/LAN, TCP vs QUIC is invisible for a POC. QUIC's loss-resilience/HoL-avoidance benefits are a native-feel optimization for lossy links (M6), behind the same transport boundary. Certificate pinning + TLS 1.3 are identical on both paths, so the security model carries over unchanged.

## [2026-06-02] Bleeding-edge OS only (macOS 26 / iOS 26, Apple Silicon)

**Decision**: Target only current OS; no legacy fallbacks.
**Rationale**: Unlocks newest ScreenCaptureKit, Core Audio process taps, VideoToolbox HEVC low-latency, modern NetworkConnection QUIC API, Swift 6 concurrency. Simpler, higher-quality build. User runs current devices.

## [2026-06-02] Name "Porthole", license Apache-2.0

**Decision**: Project name **Porthole**; license **Apache-2.0**.
**Rationale**: "Porthole" = a small round window onto the full Mac. Apache-2.0 = permissive + explicit patent grant (safer than MIT for a project implementing a network protocol and touching codecs).

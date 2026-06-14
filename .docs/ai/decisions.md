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

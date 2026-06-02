# Portview — Design Spec

> **Portview** is an open-source, native-feeling iPhone → Mac screen-sharing and control app. It replaces the laggy VNC experience with a hardware-codec video stream over QUIC, the way Apple's own Mac-to-Mac screen sharing feels — but fully open, end to end.

- **Status:** Design approved 2026-06-02. Implementation starting at milestone M0.
- **License:** Apache-2.0
- **Targets:** macOS 26+ / iOS 26+, Apple Silicon only. Swift 6.2, Xcode 26.
- **Repo role:** This is the canonical design. `.docs/ai/` holds terse handoff state that points here.

---

## 1. Goal & shape

One sentence: *a Mac menu-bar helper captures the screen and streams hardware-encoded HEVC over an encrypted QUIC connection to a native iPhone app that decodes, renders, and sends back trackpad-style input — direct on the LAN, or over the user's own Tailscale for remote.*

Two apps + one QUIC connection carrying six logical lanes. No servers we host. The iPhone is purely a **viewer/controller** (decode + input), which sidesteps every iOS screen-capture and background restriction.

### Why this shape (validated by research)

- Apple's fast "High Performance" Mac-to-Mac path is **proprietary, Apple-silicon-only, undocumented** (UDP 5900–5902; the legacy fast path uses Apple's private MVS RFB encodings). A third-party client connecting to macOS's *built-in* Screen Sharing server is stuck on the slow raw/zlib framebuffer path — i.e. exactly the VNC lag we are escaping. **The only way to native feel is to own the host agent.**
- The host-side enablers Apple itself uses are **fully public**: ScreenCaptureKit capture + VideoToolbox low-latency hardware HEVC/H.264 encode on the same Apple-silicon Media Engine. CGEvent injection for input. Core Audio process taps for audio.
- Building clean-room on Apple frameworks (no GPL references like Lumen/Moonlight) is what lets us ship a permissive **Apache-2.0** license.

## 2. Product decisions (locked)

| # | Decision | Choice | Why |
|---|----------|--------|-----|
| D1 | Mac side | **Own host agent** (not built-in-server interop) | Only path to native feel; keeps us fully open-source. |
| D2 | Connectivity | **LAN-direct, overlay-friendly** (Bonjour + direct; remote via the user's Tailscale/WireGuard) | Zero servers to host; a Tailscale endpoint looks like a remote host and "just works." |
| D3 | Input model | **Trackpad-style** (relative cursor, tap-click, two-finger scroll) | Precise control of a full desktop on a small screen. Direct-touch is a later mode. |
| D4 | Transport/codec | **Custom protocol over QUIC** (Network.framework), hardware HEVC (H.264 fallback) | Native APIs, TLS 1.3 built in, stream multiplexing, zero deps → permissive license. |
| D5 | OS targets | **Bleeding edge only** (macOS 26 / iOS 26, Apple Silicon) | No legacy fallbacks; unlocks newest capture/encode/QUIC APIs. |
| D6 | v1 feature scope | view+control+keyboard+discovery+pairing+saved-Macs **plus** audio, clipboard, file transfer, multi-monitor | Full-featured product; sequenced as milestones M0–M6. |
| D7 | Name / license | **Portview** / **Apache-2.0** | — |

## 3. Out of scope (and why)

- **Remote-unlocking a logged-out/locked Mac.** ScreenCaptureKit is unavailable pre-login and Secure Input blocks synthesized keystrokes at password fields. The Mac must already be logged in. *(Hard public-API limit, not a v1 cut.)*
- **Internet relay / NAT traversal / accounts.** No STUN/TURN/rendezvous server. Remote access is delegated to the user's existing overlay VPN (Tailscale). *(Keeps us serverless; revisit only if demand appears.)*
- **Intel / T2 Macs.** Apple-silicon only (HEVC low-latency encode is an Apple-silicon feature).
- **iPhone-as-source** (sharing the phone screen to the Mac). Portview is iPhone-as-controller only.
- **Virtual displays** (CGVirtualDisplay "iPhone as second display"). Noted as a future direction; not v1.

## 4. System architecture

```
┌──────────────────────────────────────────────┐
│ 🖥️  MAC HOST  (menu-bar app + SMAppService LaunchAgent, GUI session) │
│   CaptureEngine    ScreenCaptureKit / SCStream  (per-display, 60fps)   │
│   VideoEncoder     VideoToolbox HEVC low-latency (H.264 fallback)      │
│   AudioTap         Core Audio process tap → encode                     │
│   InputInjector    CGEvent (mouse/scroll/keyboard, global coords)      │
│   QuicServer       NetworkListener (QUIC, TLS 1.3)                      │
│   Discovery        Bonjour advertise  _portview._udp                   │
│   PairingStore     authorized device keys (revocable)                  │
│   Permissions      TCC onboarding (Screen Recording + Accessibility)   │
└──────────────────────────────────────────────┘
        ⇅  QUIC connection — TLS 1.3, server cert pinned at pairing  ⇅
        six logical lanes (see §5):
          video (lossy-ok, push) · audio (lossy-ok) ·
          input (reliable, prioritized) · control (reliable) ·
          clipboard (reliable) · files (reliable, bulk)
┌──────────────────────────────────────────────┐
│ 📱  iPHONE CLIENT  (SwiftUI; pure viewer + controller)                 │
│   Discovery        NWBrowser (Bonjour) + manual add (Tailscale host)   │
│   QuicClient       NetworkConnection (QUIC)                            │
│   VideoDecoder     VideoToolbox hardware decode                        │
│   MetalRenderer    CAMetalLayer  (lowest-latency render path)          │
│   InputController  trackpad gestures → input messages                  │
│   SessionView      screen surface + on-screen keyboard + toolbar       │
│   Feature modules  clipboard · files · audio playback · display switch │
└──────────────────────────────────────────────┘
```

The host **must** run as a per-user agent inside the logged-in GUI session (a root LaunchDaemon cannot capture the screen or inject input).

## 5. Wire protocol (the contract)

The protocol is the riskiest, most-shared piece and is built/tested first. It is implemented in a pure-Swift `PortviewProtocol` package with deterministic binary encoding and round-trip tests — no Xcode, no device, `swift test`-able.

### Transport mapping (QUIC, one connection)

| Lane | QUIC mapping | Reliability | Direction | Carries |
|------|--------------|-------------|-----------|---------|
| **control** | one bidirectional stream | reliable, ordered | both | handshake, capability negotiation, display list, quality/keyframe commands, pause/resume, status/error |
| **input** | one bidirectional stream, high priority | reliable, ordered | client → host | pointer move (relative + absolute), button up/down, scroll, key up/down, modifiers |
| **video** | QUIC **datagrams** if available on iOS 26, else one unidirectional stream per frame with stale-drop | unreliable / drop-stale | host → client | encoded access units + frame metadata (seq, pts, frame type, display id, dimensions) |
| **audio** | datagrams / unidirectional stream | unreliable | host → client | encoded audio packets + pts |
| **clipboard** | bidirectional stream | reliable | both | clipboard updates (UTF-8 text in v1) |
| **files** | bidirectional stream | reliable, bulk | both | transfer offer / chunk / ack / complete |

> **To verify early (M0):** whether iOS 26 QUIC exposes unreliable DATAGRAM frames (RFC 9221). If yes, video/audio ride datagrams. If no, fall back to per-frame unidirectional streams that we close + replace so stale frames never head-of-line-block. Either way the **video lane is push-based with stale-drop** — the core mechanism that makes this feel native instead of VNC's request-reply.

### Message framing

Each logical message: `[varint payloadLength][uint8 messageType][payload]`. Payloads are versioned, explicit binary encodings (not opaque `Codable`) so the format is stable and inspectable. A `protocolVersion` integer is exchanged in the handshake; both sides negotiate `min(supported)`.

### Session handshake (control lane)

1. Client opens QUIC connection; TLS validates the **pinned** server identity from pairing.
2. `ClientHello { protocolVersion, deviceId, deviceName, caps (codecs, maxDecodeRes/fps) }`
3. `ServerHello { protocolVersion, caps, displays:[{id,name,w,h,scale}], chosenCodec }`
4. `StartSession { displayId, codec, maxResolution, maxFps, targetBitrate }`
5. Host begins streaming on the video lane; input/clipboard/files lanes become live.
6. Either side may send `Bye`/`Error` with a reason code.

### Pairing (out of band, separate from session)

- The Mac shows a **QR** encoding `{ serverName, hostCandidates[], port, serverCertSPKIFingerprint, pairingCode }`.
- The phone scans, generates its own device keypair, and connects; it presents `devicePubKey + pairingCode`.
- The host validates the code, stores the device's public key in `PairingStore` (authorized, revocable), and pins occur both ways. The UI **surfaces device fingerprints for verification** — no blind trust.
- Thereafter: QUIC TLS 1.3 with the pinned server identity + device-key authorization. No password reuse.

## 6. Components

**Shared SPM libraries (built first, tested hardest):**
- `PortviewProtocol` — lane definitions, message types, binary framing, handshake state machine, version negotiation. Pure Swift, fully unit-tested.
- `PortviewTransport` — thin QUIC wrapper over Network.framework (listener + connection + per-lane streams/datagrams). Shared by both apps.

**Mac host (`PortviewHost`, menu-bar app):** `CaptureEngine`, `VideoEncoder`, `AudioTap`, `InputInjector`, `QuicServer`, `Discovery`, `PairingStore`, `PermissionsCoordinator`, `AppLifecycle` (SMAppService).

**iPhone client (`PortviewClient`, SwiftUI):** `Discovery`, `QuicClient`, `VideoDecoder`, `MetalRenderer`, `InputController`, `SessionView`, feature modules (clipboard/files/audio/displays), `PairingFlow` (QR scan), `SavedMacsStore`.

## 7. Data flow & latency budget

**Frame path:** SCStream callback (CVPixelBuffer) → VideoToolbox encode (HEVC, low-latency, no B-frames) → packetize → QUIC video lane → depacketize → VideoToolbox decode → CVPixelBuffer → MTLTexture → CAMetalLayer present.

**Input path:** UITouch/gesture → relative delta or absolute point → input message → QUIC input lane → CGEvent synthesized at global coordinates → injected.

**Budget (LAN, target):** capture ≈ frame interval + encode ~10–15 ms (HEVC 1080p60) + network < 5 ms + decode < 15 ms + ~1 frame render ⇒ **< 50 ms motion-to-photon at 60 fps** (stretch < 30 ms). Above ~75–100 ms it stops feeling native. Sidecar's wireless bar is ~44–70 ms, so < 50 ms LAN is competitive.

**Flow control:** video lane is **push with stale-drop**. On loss bursts the client requests an IDR keyframe (control lane) and the host drops target bitrate/fps; recovery ramps back up (M6 adaptive quality).

## 8. Error handling & resilience

- **Permissions not granted (host):** guided onboarding; detect via `CGPreflightScreenCaptureAccess()` and `AXIsProcessTrusted()`. Cannot stream/inject until both granted. Ship a signed `.app` so grants appear in Settings and persist.
- **Secure Input active (password fields):** synthesized keystrokes are silently dropped. Detect `IsSecureEventInputEnabled()` and show a "secure field — typing paused" banner on the phone. Pointer still works.
- **Connection loss:** exponential-backoff reconnect on the client; host tolerates client disappearance.
- **iOS backgrounding:** session is **foreground-only**; on background, tear down cleanly. Use APNs/PushKit to re-wake and auto-reconnect when the user returns. *(Not the "30s broadcast" myth — that's about iPhone-as-source, which we don't do.)*
- **Display config change / Mac sleep:** re-negotiate display list; pause/resume the stream.
- **Multi-monitor coordinates:** CGEvent uses a global top-left-origin, Y-down space spanning all displays; reconcile with NSScreen bottom-left frames in `InputInjector`.

## 9. Constraints & risks (from research)

- App Store **4.2.7** permits a generic full-desktop mirror of a user-owned Mac. Avoid any store-like browse/purchase UI (IAP-circumvention sub-points). Re-verify the live guideline number at submission.
- Two separate macOS TCC grants required: **Screen Recording** and **Accessibility**.
- QUIC requires TLS 1.3 + a digital identity (TLS-PSK is 1.2-only) — pairing must provision a cert/identity to pin.
- Open verifications: iOS 26 QUIC datagram support; exact macOS version where the VideoToolbox `EnableLowLatencyRateControl` flag covers HEVC; `SCStreamConfiguration.showsCursor` behavior (render our own cursor overlay if the hardware-cursor path is buggy).

## 10. Testing strategy

- **Unit (TDD):** `PortviewProtocol` message encode/decode round-trips, version negotiation, framing edge cases; input coordinate mapping (multi-monitor). Swift Testing.
- **Integration:** loopback host↔client on one Mac; then real LAN end-to-end.
- **Latency harness:** on-screen timestamp/QR round-trip to measure motion-to-photon and hold the < 50 ms line; track encode/decode times.
- **Manual device matrix:** small (bleeding-edge only) — current iPhone + current Mac.

## 11. Milestone roadmap

Each milestone is independently shippable and verifiable.

- **M0 — Walking skeleton:** `PortviewProtocol` package (TDD) + minimal `PortviewTransport`; host captures one display → HEVC encode → QUIC → client decode → Metal render. No input/pairing, hardcoded LAN address. **Verify:** live Mac screen on the phone, < 50 ms.
- **M1 — Control + connect:** trackpad input (CGEvent) + on-screen keyboard; Bonjour discovery; QR pairing + pinned-cert security; saved-Macs list. **Verify:** discover, pair, and actually drive the Mac.
- **M2 — Clipboard sync** (text, both directions).
- **M3 — Multi-monitor** (pick/switch display).
- **M4 — Audio** (Core Audio process tap → encode → A/V-synced playback).
- **M5 — File transfer** (files lane).
- **M6 — Polish** (adaptive bitrate/fps, reconnect + push re-wake, settings, quality HUD).

## 12. Repo structure

```
portview/
  Package.swift                      # SPM workspace for shared libs
  Sources/
    PortviewProtocol/                # pure-Swift wire protocol  ← M0 starts here
    PortviewTransport/               # QUIC wrapper (Network.framework)
  Tests/
    PortviewProtocolTests/
    PortviewTransportTests/
  apps/
    PortviewHost/                    # macOS menu-bar app (Xcode project)
    PortviewClient/                  # iOS app (Xcode project)
  docs/superpowers/specs/            # this spec
  .docs/ai/                          # handoff state (roadmap, current-state, decisions, phases)
  LICENSE  README.md  .gitignore
```

The two apps depend on the local SPM packages. M0 needs only `swift build` / `swift test` — no Xcode, signing, or simulator.

## 13. Framework reference (per layer, min versions)

- **Capture:** `ScreenCaptureKit` / `SCStream` + `SCContentFilter` + `SCStreamConfiguration` (`minimumFrameInterval` = `CMTime(value:1, timescale:60)`; `showsCursor`).
- **Encode:** `VideoToolbox` `VTCompressionSession`, `kVTVideoEncoderSpecification_EnableLowLatencyRateControl = true`, `AllowFrameReordering=false`, `RealTime=true`, `MaxKeyFrameInterval`. HEVC on Apple silicon; H.264 fallback.
- **Input inject:** `CGEventCreateMouseEvent/…KeyboardEvent/…ScrollWheelEvent` + `CGEventPost(kCGHIDEventTap,…)`; global display coordinates.
- **Audio:** Core Audio process taps — `CATapDescription` + `AudioHardwareCreateProcessTap` + aggregate device (needs `NSAudioCaptureUsageDescription`).
- **Host packaging:** Developer ID signed + notarized + Hardened Runtime; `SMAppService` LaunchAgent.
- **Decode (iOS):** `VideoToolbox` `VTDecompressionSession`; SPS/PPS (H.264) or VPS/SPS/PPS (HEVC) via `CMVideoFormatDescription`.
- **Render (iOS):** `CVPixelBuffer` → `MTLTexture` in `CAMetalLayer`.
- **Input capture (iOS):** `UITouch`/gestures; optional `GCMouse`/`GCKeyboard`, `UIPress`/`UIKey`.
- **Transport/discovery:** `Network.framework` — iOS 26 `NetworkConnection`/`NetworkListener`/`NetworkBrowser` with explicit QUIC streams; Bonjour needs `NSLocalNetworkUsageDescription` + `NSBonjourServices`.

## 14. Open questions to resolve during M0

1. iOS 26 QUIC: are unreliable DATAGRAM frames available? (Decides video/audio lane mapping.)
2. Does `EnableLowLatencyRateControl` officially cover HEVC on macOS 26? (Else pin H.264 for the low-latency path.)
3. Empirical ScreenCaptureKit→render motion-to-photon on this hardware (build the latency harness early).

# Architecture Review — Portview (2026-07-01)

> Authored by Fable 5 via a six-lens adversarial-review workflow (each lens read
> the real code; critical/high findings were independently refuted before
> acceptance). Output = proposed ADRs + a fleet-dispatchable beads backlog for
> Opus / Sonnet 5 / GPT-5.5 / open-source models to execute. Every work item is
> machine-verifiable (a runnable `swift test`/`xcodebuild`); device-observable
> effects are separate human-gated follow-ups.

## Lenses run

concurrency · wire-protocol · media/render · security · module-boundaries · roadmap-fit.
(3 lenses lost their first structured output to a probe-call bug and were re-run;
protocol + boundaries were finished as direct prose agents after a StructuredOutput
retry-cap failure. All findings below are code-cited and verified.)

## The five load-bearing findings

1. **Unknown wire tags silently, permanently wedge the connection (protocol).**
   Framing is length-prefixed, but `Frame.decodeBody` throws `unknownMessageType`
   *before* `FrameDecoder` removes the frame from the buffer; `PortholeConnection.receiveNext`
   swallows the throw with `try?`; the inbound stream never finishes → infinite re-throw
   on the head-of-line poison frame with an unbounded buffer. **Consequence: adding ANY new
   tag to a new client talking to an old host is a session-killing break today.** This makes
   "skip unknown tags" the dependency ROOT for every new-message item the fleet will add.

2. **The host authenticates no client (security, critical).** `QUICParameters.server`
   installs only a local identity (no client-verify block); `serveSession` grants full
   keyboard/mouse/clipboard/file control to any peer completing a bare `ClientHello`. The
   pin is a client-side host-verification secret only, never required of the client; the SAS
   window is consulted only on the preamble path, never on the streaming path. On the intended
   trusted overlay VPN (Tailscale/WireGuard/home LAN) exposure is bounded to your own devices;
   on any shared LAN a single hostile device owns the Mac. This is the unbuilt M6
   "device keypairs + revocable PairingStore."

3. **The locked-screen input gate is client-side only (security, critical).**
   `InputInjector.handle` posts CGEvents unconditionally; the only pause gate lives in the iOS
   client. A modified client injects into a locked Mac / login window. Cheap host-side fix.

4. **The M6 "polish" features share one missing foundation (media/roadmap).** Adaptive
   bitrate, the <50 ms latency harness, and A/V lip-sync all independently need infrastructure
   that doesn't exist: no live encoder-bitrate setter (bitrate is init-only → a change forces
   the crash-adjacent encoder rebuild), no client→host feedback channel (QualityStats is
   host→client only), no RTT/clock primitive, no presentation clock (audio plays back-to-back,
   video is newest-wins, both carry unused `ptsMicros`). Build the RTT/clock + feedback keystone
   once; the three features ride on it.

5. **The client has no testable core; two 750-line god files (boundaries).** The host has
   `PortviewHostCore`; the client has none — all client logic is trapped in the iOS app target,
   so even pure CoreGraphics geometry needs the simulator to test. Standing up `PortviewClientCore`
   is the single highest-leverage Lead extraction: it turns most future client work into
   junior-ownable pure types verified by `swift test`, and unblocks a fast CI gate.
   Also: a real cross-task data race on `CaptureEngine.config`/`stream` (`@unchecked Sendable`
   hides it), and serve-slot starvation from unbounded first-message reads.

## Proposed decisions (PROPOSED — ratify or amend)

- **A. Unknown tags MUST skip, never wedge; version field is threaded and used; golden-frame
  KAT + reserved tag ranges gate the wire** so a multi-model fleet can add tags without silent
  breaks. (EPIC `screenshare-1n6`.)
- **B. Host authenticates clients via device keypairs + a revocable, keychain-backed
  PairingStore**, verified in the streaming handshake before any scaffolding is built; lock
  gate + file/clipboard caps enforced host-side. Lead-tier spec first, SAS-style review arc.
  (EPIC `screenshare-1nt`.)
- **C. Real-time media rides one keystone** — Ping/Pong RTT + clock offset, a live
  `VideoEncoder.setAverageBitRate` (no session rebuild), and a client→host feedback message —
  then adaptive bitrate, a pure presentation clock, and PTS-based lip-sync. (EPIC `screenshare-ja1`.)
- **D. Stand up `PortviewClientCore` once**, then decompose the god files as pure value types
  mirroring `HostSessions`/`ZoomGeometry`; local `make preflight` pre-push gate (no hosted
  macOS-26 runner yet). GlassTheme stays per-app (only ~60 shared lines; components diverge
  intentionally). (EPIC `screenshare-jfj`.)
- **E. Fix the CaptureEngine data race and serve-slot starvation**; move toward actor isolation
  and a session-owned host outbound lane. (EPIC `screenshare-523`.)

## User decisions (recorded 2026-07-01)

- **Threat model = local LAN / Tailscale / WireGuard.** Mutual-auth is P1 (the M6 keypairs item),
  not a drop-everything P0; but a real exposure on untrusted LAN — flagged in EPIC `screenshare-1nt`.
- **Re-wake = CloudKit silent push** (own iCloud, no hosted server). Spec bead `screenshare-8qi`.
- **Fleet does all four clusters** + forward planning (this report).

## Epic map (beads)

| Epic | ID | Priority | Root(s) ready now |
|---|---|---|---|
| Wire-compatibility safety net | `screenshare-1n6` | P0 | `w-skip` (kyf), `w-golden` (73y) |
| PortviewClientCore + decomposition | `screenshare-jfj` | P1 | `cc-target` (1j0), `cc-hostsplit` (5xp), `cc-cigate` (950) |
| Host trust model (mutual auth) | `screenshare-1nt` | P1 | `t-lockgate` (q67), `t-filecap` (dhx), `t-spec` (7jl) |
| Real-time media foundation | `screenshare-ja1` | P2 | `m-pingpong` (nl1), `m-bitrate` (vzf), `vs9` latency harness |
| Concurrency correctness | `screenshare-523` | P2 | `x-capturerace` (6b8), `x-deadline` (ccx), `x-outlane` (8bm) |

35 new beads (5 epics + 30 tasks) with a verified 20-edge dependency graph (no cycles).
Existing beads enriched to the dispatchable spec: `vs9` (loopback latency harness), `ins`
(lip-sync → device-verify of `m-present`), `10p` (QUIC lane-splitting, gated on the latency
baseline; note the `Lane` enum is dead code), `627` (per-source SAS rate-limit). Closed `8ds`
(client outbound serialization already done — `OutboundInputPump`).

## Recommended execution order for the fleet

1. **`w-skip` (kyf) first** — it is the root that makes every later wire addition safe. Then
   `w-golden` (kyf-independent) so the KAT exists before new tags land.
2. **`cc-target` (1j0)** — unblocks the whole junior fan-out (cc-zoom/cursor/statics + later
   PresentationClock). Cheap models can then own most client work.
3. In parallel: **`t-lockgate` + `t-filecap`** (cheap host-side security), **`x-capturerace`**
   (the data race), **`m-bitrate` + `m-pingpong`** (media keystone, m-pingpong after w-skip).
4. Lead-tier specs (`t-spec`, `r-cloudkit-spec`, and a QUIC lane-splitting spec) gate their
   impl children; author them before dispatching the XL security/transport work.
5. QUIC lane-splitting (`10p`) LAST, gated on the latency baseline (`vs9`).

## Future directions (beyond the review findings)

- **Multi-viewer / presenter mode** — `HostControl`/`KeepAwake` are already session-set-keyed,
  so N simultaneous read-only viewers is a smaller step than it looks once mutual-auth lands.
- **`SECURITY.md`** documenting the trust model — valuable for an Apache-2.0 project others run.
- **Rich clipboard (images) + drag-and-drop file transfer** once the file/clipboard channels are
  consent-gated and capped.
- **Settings + TCC onboarding UI polish** (the remaining un-decomposed M6 tail).

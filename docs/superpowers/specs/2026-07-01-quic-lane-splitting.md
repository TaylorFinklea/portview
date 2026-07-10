# Spec — QUIC lane-splitting (head-of-line isolation for input vs video)

> Lead-authored (Fable 5, 2026-07-01). The design gate demanded by bead
> `screenshare-10p` ("sequence LAST, after the latency baseline… and after a lead-tier
> lane-splitting design spec"). Implementation stays gated on `screenshare-vs9`
> (latency harness) proving the win is measurable, and on `screenshare-350`
> (negotiated protocol version) for capability gating.

## Review fold (2026-07-02 — protocol/Network.framework must-fixes)

A design review + against-source verification (all refs verified 2026-07-02) corrected
five load-bearing errors in the first draft; the body below is the corrected design:
1. **Token direction** — the host-minted session token rides **`ServerHello`** (host→client,
   appended after `chosenCodec`), NOT `StartSession`. `StartSession` is client→host
   (`StartSession.swift:1`) and cannot carry a host secret; a client-minted token would let
   a peer collide another session's token.
2. **Lane streams are BIDIRECTIONAL** — a client-opened *unidirectional* QUIC stream flows
   client→host only, so it cannot carry host→client video. The client opens bidi streams,
   writes only the preamble, then goes quiet. Unidirectional half-closure is a phase-2
   question, not phase 1.
3. **Stream classification** — an explicit first-byte rule distinguishes a secondary lane
   preamble from a legacy primary / SAS connection, so "unknown lane → close" doesn't kill
   every old client and every pairing connection.
4. **Per-tunnel stream cap** — phase 1 needs exactly 3 secondary streams; the current
   100 bidi / 1000 uni allowance (`QUICParameters.swift:10-11`) is bounded so one peer can't
   open a stream flood into unbounded per-stream inbound buffers.
5. **Lane-death keyframe recovery** — a lane flip forces an encoder keyframe (the HEVC delta
   chain otherwise references lost frames forever); preserve the accidental
   rebuild-and-keyframe that today's `pumpVideo` catch already gives.
Plus: the `stats` lane needs a real `Lane` enum case (there is none today), and `VideoFrame`
**already carries `sequence`** (`VideoFrame.swift:4`) — no new field needed. This is plain
protocol / transport / Network.framework work — no cryptographic content beyond "mint a
random token, compare it constant-time," which is deferred to the security-review pass.

## Problem (verified)

`PortviewConnection` is ONE bidirectional QUIC stream: one `NWConnection`, one
`FrameDecoder`, one inbound `AsyncStream` (PortholeConnection.swift:15-33). Every
message class shares that ordered byte stream, so:

- **Wire HOL**: a lost UDP packet carrying video bytes stalls delivery of every frame
  behind it in the stream — including cursor echoes and clipboard — until retransmit.
  Invisible on LAN; real on Tailscale/WAN paths.
- **Sender HOL**: `send` serializes whole frames (PortholeConnection.swift:72-79); a
  multi-hundred-KB `VideoFrame` queued ahead of a `PointerMove` delays it by full
  transmission time even with zero loss.
- A `Lane` enum exists (Sources/PortviewProtocol/Lane.swift — control/input/video/
  audio/clipboard/files) but is DEAD: used nowhere, and the frame header
  `[varint bodyLength][uint8 messageType][payload]` (Frame.swift:1-14) carries no lane.

Send sites that would re-route (verified): host `pumpVideo` video/audio/qualityStats
(HostRunner.swift:610-692), clipboard push (HostRunner.swift:440), `HostControl.broadcast`
+ `sendFile` (HostControl.swift:39-66); client `OutboundInputPump`, viewport requests,
ping, clipboard, file chunks (SessionViewModel + pump).

## Options evaluated (the bead's required comparison)

| Option | Verdict | Why |
|---|---|---|
| **A. Lane-tagged frames over the existing single stream** | Rejected as the end-state; *chunk-interleaving variant deferred* | A lane byte on one ordered stream fixes nothing at the QUIC level — retransmit still stalls the whole stream. Sender HOL alone could be eased by splitting big frames into interleavable chunks, but that reimplements QUIC streams badly (framing churn, reassembly, no loss isolation). |
| **B. `NWConnectionGroup` (`NWMultiplexGroup`) — real QUIC streams** | **CHOSEN** | The supported Network.framework API for multiple streams on ONE QUIC tunnel (one handshake, one cert-pinning evaluation, shared congestion control). Streams are independently ordered → loss on video no longer stalls input. |
| **C. Per-frame unidirectional `NWConnection`s (bare, no group)** | Rejected | Client-side, a bare `NWConnection` per frame is a separate QUIC handshake per frame (nothing ties it to the tunnel); the listener-side "each inbound stream arrives as a connection" behavior (PortholeConnection.swift:167-171) doesn't give the client an API to OPEN tunnel-sharing streams without a group. |

## Design

### Phase 0 — spike (must precede everything)

Loopback spike answering, with a runnable test as the artifact:

1. Client `NWConnectionGroup(with: NWMultiplexGroup(...))` over QUIC → host bare
   `NWListener(quicIdentity:)`: do peer-opened streams arrive via the existing
   `newConnectionHandler`, and can the host associate them to their tunnel (via
   `sec_protocol_metadata` peer identity or grouped delivery)? Or does the host also
   need an `NWConnectionGroup` listener?
2. Does cert pinning evaluate once per tunnel or per stream?
3. Interplay with the known QUIC double-delivery quirk (PortholeConnection.swift:36-38).
4. Half-closure semantics for unidirectional streams (`isComplete` on final write).

The spike's answers pick between the two association mechanisms below; everything
after phase 0 is written to work with either.

### Stream topology (phase 1 — lane streams)

Four long-lived streams per session, opened by the CLIENT (client-initiated streams
sidestep server-open/accept asymmetries):

- **primary (bidi)** — the existing stream, unchanged: handshake, control, input,
  cursor, clipboard, SAS, ping/pong, file offers/chunks. Everything small stays here.
- **video (bidi, host→client payload)** — `VideoFrame` only.
- **audio (bidi, host→client payload)** — `AudioFrame` only.
- **stats (bidi, host→client payload)** — `QualityStats` (+ future telemetry), so a video
  burst can't delay the HUD.

**Secondary streams MUST be bidirectional.** A client-opened *unidirectional* QUIC stream
carries data initiator→peer only (macOS 26 SDK: `NWProtocolQUIC.Options.direction {
bidirectional, unidirectional }`, fixed at open time), so a client-opened uni stream can
never carry host→client video/audio/stats. The client OPENS each secondary stream (bidi),
writes ONLY the preamble on its send side, then stays quiet (optionally half-closing its
send side); the HOST sends frames on the same stream. "Receive-only from the client's
side" describes intent, not a uni stream. The host must bound/ignore any post-preamble
client bytes on a host→client lane (see the per-tunnel cap below) so an attacker can't feed
the host an open-ended decode loop on a lane. File transfer stays on primary in phase 1
(chunks are 64KB-ish and already interleave; promote later only if measurements say so).

**Stream preamble** (first bytes on every secondary stream):
`[uint8 laneRawValue][32B sessionToken]` — then normal frames. The `sessionToken` is
minted per-session by the host and delivered to the client on the primary stream via a
**`ServerHello` append-only field** (host→client — `ServerHello.swift:1`, appended after
the last field `chosenCodec`; presence gated on the negotiated protocol version so an old
client that stops decoding after `chosenCodec` is unaffected). It is NOT carried on
`StartSession`: that message is client→host (`StartSession.swift:1`, produced by
`ClientHandshake.handle` and consumed at `HostRunner.swift:510-514`), so it structurally
cannot deliver a host-minted value, and letting the client mint the token would let a
malicious client collide another live session's token in the host's token→session map.
The token is REQUIRED on secondary streams so the host binds each stream to an
authenticated session even if the spike shows tunnel association is invisible at the
listener; if native tunnel association works, the token stays anyway (defense in depth,
33 bytes once per stream). Token hygiene (CSPRNG mint, constant-time compare,
invalidate-on-teardown, never logged — today's host logging is bare `print()`) is folded
into the security-review pass, not designed here.

**Stream classification (first byte discriminates).** On the host, every inbound QUIC
stream arrives as a fresh `PortviewConnection` whose bytes go straight into a
`FrameDecoder`; `serveSession` classifies by peeking the first decoded message
(`HostRunner.swift:420-435`). A secondary lane stream instead starts with a raw preamble
whose first byte is a `Lane` raw value (0–6). A legacy/new **primary** connection starts
with a `ClientHello` *frame* whose first byte is the varint `bodyLength` (≥ 6; golden
vector = 16, `GoldenFrameTests.swift:43`); a **SAS** connection's first byte is 33
(`GoldenFrameTests.swift:141`). So the classifier is: **first byte ≤ 6 → treat as a lane
preamble; otherwise → the existing frame path (primary/SAS).** This rests on the invariant
"no legitimate first frame has `bodyLength ≤ 6`" — state it explicitly and add a golden
guard test, because a naive "unknown lane byte → close" applied at the accept path would
close first-byte-16 (primary) and first-byte-33 (SAS), breaking host-new/client-old interop
and pairing entirely.

- Within the lane path, an unknown lane byte (7…) or bad token → close **that stream only**;
  session unaffected. A second stream presenting a valid token for an ALREADY-bound lane
  (duplicate video lane) → reject/close the duplicate (don't let a token-holder bind N
  "video" streams and multiply host send work).
- Secondary streams accepted only AFTER the primary-stream handshake completes (and,
  once the mutual-auth epic lands, only after client verification — the auth gate
  covers stream acceptance too; note this dependency in both directions).

### Per-tunnel stream cap & buffering (DoS bound)

Phase 1 needs exactly **3** secondary streams per session. Today the server allows 100 bidi
+ 1000 uni streams per tunnel (`QUICParameters.swift:10-11`, in `baseOptions()` shared by
server + client), and every peer-opened stream lands in `newConnectionHandler`
(`PortholeConnection.swift:189-194`), which builds a `PortviewConnection`, starts its
receive loop, and yields into an **unbounded** inbound `AsyncStream`
(`PortholeConnection.swift:32`, `makeStream()` default) BEFORE the 16-slot
`serveConnections` cap ever sees it. So the connection cap bounds serve *tasks*, not live
streams: an unserved stream buffers everything an attacker blasts at it (memory
amplification from one tunnel), and garbage-preamble streams each hold a serve slot for the
5 s deadline. Bound this:

- Lower the per-tunnel QUIC stream allowance toward what lanes actually need (a small bidi
  ceiling, e.g. primary + 3 lanes + headroom), or enforce an application-level per-tunnel
  secondary-stream count and reject opens past it.
- Give per-stream inbound buffering a bound (the video lane already wants newest-N — see
  epic `screenshare-523`'s inbound-backpressure item; the lane work should not widen the
  unbounded-buffer surface).
- Preamble reads get the first-message deadline treatment, but note the existing
  `x-deadline`/`HandshakeDeadlineTests` helper operates on decoded `AnyMessage` streams —
  the preamble is raw pre-framing bytes at the transport layer, so it needs its own bounded
  raw-read deadline, not a direct reuse.

### Per-stream decode & merge

- One `FrameDecoder` per stream (frames MUST NOT straddle streams — each stream is its
  own self-delimiting byte sequence).
- Client keeps ONE logical inbound `AsyncStream<AnyMessage>` merged from all lanes
  (arrival order across lanes is already unordered on the wire; per-lane order is
  preserved by QUIC stream ordering — exactly the ordering contract the app has
  today, since cross-message ordering across types was already eliminated as a
  correctness dependency by the VideoFrame-carries-viewport work). Consumers
  (`streamSession`'s switch) do not change.

### Lane enum + wire additions

The `Lane` enum (`Lane.swift:1-9`) today has exactly 6 cases (`control=0, input=1, video=2,
audio=3, clipboard=4, files=5`) and **no `stats` case** — add `stats = 6` (append-only, the
raw value becomes wire-frozen; it is the preamble byte for the stats lane). Note stats
today are NOT a lane: they ride the `.qualityStats` control message (`HostRunner.swift:692`);
lane-splitting moves them onto the stats stream. `lane-proto` must add the golden-frame
vector + `EnumTests` set entry for the new case (the wave-1/2 wire-safety gates), and the
preamble/token codec + the `ServerHello` token field (append-only + golden KAT).

### Capability negotiation & compat

- New protocol version (bump `ProtocolVersion.current`; `minimum` stays 1). Lane
  support = `negotiatedVersion >= laneVersion` — this is WHY `screenshare-350`
  (thread negotiated version out of the handshake) is a hard dependency.
- Old peer ↔ new peer: everything flows on primary exactly as today. New↔new:
  host sends video/audio/stats on lanes. The host must handle a lane-capable client
  that never opens lanes (client choice/failure) by falling back to primary after a
  bounded wait (2 s) — never stall a session waiting for streams.

### Phase 2 — per-frame video streams (separate, measurement-gated)

Only after phase 1 ships AND `vs9` + Tailscale measurements show residual video-lane
HOL matters: one unidirectional stream per video frame (open → preamble → frame →
finish), client reassembles by the EXISTING `VideoFrame.sequence` field (`VideoFrame.swift:4`,
already a monotonic `UInt64` maintained by `pumpVideo` — no new field needed), drops any
frame older than the newest completed keyframe-chain point, host abandons (cancels) streams
for frames superseded before fully sent. This is where the real
"stale frame never blocks a fresh one" win lives, at the cost of reassembly +
sequencing complexity. Not designed further here — it gets its own spec if phase 1
measurements justify it.

## Failure modes

- Secondary stream dies mid-session → that lane falls back to primary (host-side lane
  router checks stream health per send; one flip, logged, no reconnect). **The flip MUST
  force an encoder keyframe.** Frames queued on the dying stream are lost, and the first
  frames sent on primary after the flip are HEVC deltas referencing those lost frames →
  frozen/corrupt video forever, because the encoder emits keyframes only on demand
  (`VideoEncoder` sets no `MaxKeyFrameInterval`; `pumpVideo` forces one only via
  `needsKeyframe`/crop, `HostRunner.swift:661-664`) and the client silently drops
  undecodable frames with no request-keyframe path. Note today ANY `pumpVideo` send error
  lands in the catch (`HostRunner.swift:700-706`) which rebuilds the encoder and forces a
  keyframe — a lane router that *absorbs* the send error to do the flip removes that
  accidental recovery, so it must force the keyframe itself (via
  `CaptureEngine.set(_:requestKeyframe: true)` / the `consumeKeyframeRequest` path). Also
  guard ordering: frames replayed on the not-quite-dead lane can arrive after newer
  primary-path frames — either drop-by-`sequence` on the client merge or don't replay the
  errored send (accept the loss, rely on the forced keyframe).
- Token leak: tokens are per-session, useless after `bye`/close. Enforcing "never logged"
  needs a real mechanism (default struct interpolation would dump the raw token through the
  host's bare `print()` logging) — folded into the security-review pass.
- Slow-loris on stream-open: secondary preamble reads get a bounded raw-read deadline
  (analogous to the `x-deadline` first-message pattern, but at the transport/pre-framing
  layer — the `HandshakeDeadlineTests` helper works on decoded `AnyMessage` streams and
  does not directly apply to raw preamble bytes).

## Beads this spec gates (file on acceptance; all blocked by vs9 + 350)

1. `lane-spike` — the phase-0 loopback spike + written findings appended to this spec.
   `tier_floor: senior`, `complexity: M`. Verify: new `QUICMultiplexSpikeTests` green.
2. `lane-proto` — pure protocol work: stream-preamble codec (`[uint8 lane][32B token]`),
   `Lane.stats = 6` case, the **`ServerHello` append-only token field** (NOT `StartSession`;
   version-gated + golden KAT + `EnumTests` for the new lane case), per-stream `FrameDecoder`
   conventions doc. `tier_floor: junior`, `complexity: S`. Verify: `swift test --filter LanePreamble`.
3. `lane-transport` — `PortviewConnection`/`PortviewListener` grow group-based stream
   open/accept + the first-byte stream classifier (≤6 → lane; else frame path) with its
   invariant guard test + token validation + per-tunnel stream cap + duplicate-lane reject +
   fallback. `tier_floor: senior`, `complexity: L`. Verify: loopback multi-lane integration test.
4. `lane-host` + `lane-client` — route pumpVideo/audio/stats onto lanes; client merge.
   `tier_floor: senior`, `complexity: M` each. Verify: package suite + iOS suite.
5. `lane-verify` — human Tailscale A/B: input latency under induced loss, phase-1 vs
   single-stream. Gates phase 2.

## Addendum (2026-07-08 — beads filed + post-523.5 reality check)

Filed as **epic `screenshare-w6n`** (.1 spike, .2 proto, .3 transport, .4 host, .5 client,
.6 Tailscale A/B), all gated on `vs9`; phase 2 = `screenshare-10p`. Two source drifts since
the 2026-07-02 against-source verification (re-verified 2026-07-08):

- **Bead 523.5 (commit 7da1f3d) landed the two-lane `InboundBuffer`**: the per-connection
  inbound stream is NO LONGER unbounded — `AsyncStream(unfolding:)` over `InboundBuffer`
  with 4 MiB/1 MiB hysteresis pausing the receive loop. The per-tunnel **stream-count** cap
  this spec demands is still required (each peer-opened stream gets its own
  `PortviewConnection` + `InboundBuffer`, so N streams × per-stream bound is still linear
  memory amplification), but the "unbounded per-stream inbound buffers" wording in the
  cap section above is stale.
- **Line refs drifted**: QUIC double-delivery comment now `PortholeConnection.swift:52-54`;
  `newConnectionHandler` :260; `pumpVideo` `HostRunner.swift:685-784` (catch 775-781 —
  sets `encoder = nil` + `needsKeyframe = true`); ping uptime idiom `HostRunner.swift:602`.
  The class inside `PortholeConnection.swift` is named `PortviewConnection`.

## Phase 0 spike findings (2026-07-09)

Artifact: `Tests/PortviewTransportTests/QUICMultiplexSpikeTests.swift` (6 tests, all green,
whole suite ~3 s on loopback — stream opens on an established tunnel are fast; only the
per-test handshake costs anything). All observations were stable across repeated runs on
macOS 26 / Swift 6.2. Verify: `swift test --filter QUICMultiplexSpike`.

### Q1 — group client → bare listener: do streams arrive, and can the host associate them?

**Streams arrive: YES, unchanged.** A client `NWConnectionGroup(with: NWMultiplexGroup(to:),
using: QUICParameters.client(...))` opens streams via `NWConnection(from: group)`; each one
lands on the host's EXISTING `newConnectionHandler` (`PortholeConnection.swift:260`) as a
fresh `PortviewConnection`, fully bidirectional and independently framed — a per-stream
ServerHello reply comes back on the right stream (`groupOpenedStreamsArriveViaExistingListenerHandler`).

**Association at the flat listener: NO.** Two mechanisms probed, both fail
(`secProtocolMetadataAssociationAcrossTunnels`):

- `sec_protocol_metadata_peers_are_equal` returned **true across two separate tunnels** from
  the same client (no client cert until mutual auth lands) — it compares peer identity, not
  tunnel identity.
- `NWProtocolQUIC.Metadata.streamIdentifier` numbering is per-tunnel and collides across
  tunnels (both tunnels' first app-opened bidi stream got id 4; ids were 4, 8, … — id 0 is
  consumed internally, consistent with the dead "control" delivery).

**Grouped delivery: YES — this works and is the native association mechanism.** Setting
`NWListener.newConnectionGroupHandler` delivers each inbound tunnel as ONE
`NWConnectionGroup`; that tunnel's streams then arrive via THAT group's
`newConnectionHandler` (`bareListenerGroupHandlerDeliversTunnelAsGroup`). Two caveats,
both load-bearing:

- Setting `newConnectionHandler` AND `newConnectionGroupHandler` together makes the
  listener **fail to start with EINVAL** — grouped delivery REPLACES flat delivery; there
  is no dual-mode listener.
- A legacy bare `NWConnection` dial (old primary, SAS preamble) into a group-handler
  listener ALSO arrives via the group handler, as a single-stream group — old clients keep
  working, but the host must classify that group's one stream down the existing frame path.

**API gotchas (cost this spike real time; they will bite `lane-transport`):**

- A client `NWConnectionGroup` NEVER leaves `.setup` — no state callback, no error — unless
  `newConnectionHandler` is installed BEFORE `start(queue:)`. Symptom is a silent hang.
- `NWConnection(from: group)` returns nil until the group is started.
- On loopback the group passes a transient `.waiting(ENETDOWN)` before `.ready`; treat
  `.waiting` as "keep waiting", never terminal.
- `NWConnectionGroup` can deliver `.failed` then `.cancelled` back-to-back; a
  one-shot-continuation guard is required (SWIFT TASK CONTINUATION MISUSE otherwise).

### Q2 — cert pinning: once per tunnel or per stream?

**Once per tunnel.** A counting copy of the pinning verify block ran exactly **1** time for
a tunnel carrying 3 streams (`certPinningEvaluatesOncePerTunnelNotPerStream`). Stream opens
never re-run verification — the "one handshake, one pinning evaluation" premise of option B
holds.

### Q3 — interplay with the double-delivery quirk

**The quirk persists and scales with streams: 2 opened streams → 4 connections delivered**
(consistently) at a flat `PortviewListener`; exactly the 2 opened streams carry data, the
extras are dead connections that never produce a message
(`doubleDeliveryQuirkWithGroupClient`). The existing serve-each-concurrently pattern
already tolerates them, but each dead delivery burns a `PortviewConnection` + `InboundBuffer`
+ (post-classification) a serve slot for the 5 s first-message deadline — the per-tunnel
stream cap must budget for ~2× the lane count at the flat listener. A group listener
sidesteps this accounting per-tunnel (the tunnel arrives once, as a group).

### Q4 — half-closure semantics

**Works as hoped, with one trap.** (`halfClosureSemanticsForUnidirectionalAndHalfClosedBidiStreams`)

- A client-opened **unidirectional** stream (id ≡ 2 mod 4 confirmed on the host) delivers
  payload + `isComplete` after a final write (`.finalMessage` + `isComplete: true`).
- Opening one requires passing the tunnel's OWN options object — found at
  `group.parameters.defaultProtocolStack.transportProtocol` (NOT `applicationProtocols`) —
  with `direction = .unidirectional` flipped for the open (direction is captured at open
  time; restore it after). Passing a freshly constructed `NWProtocolQUIC.Options` (with or
  without ALPN) fails the stream straight to `.failed(ENETDOWN)`.
- A **bidi** stream half-closed by the client (preamble + final write) still carries
  host→client bytes afterwards — exactly the phase-1 lane shape (client: preamble, FIN;
  host: frames forever).
- **Trap:** a host send on a client-opened uni stream reports SUCCESS (nil error) and the
  bytes silently vanish. Direction misuse is invisible at the send site; enforce direction
  by protocol, never by trusting send errors.

### Recommendation — stream-association mechanism for `lane-transport` (w6n.3)

**Adopt the group listener (`newConnectionGroupHandler`) as the association mechanism, and
keep the preamble token as defense in depth** (per the design above: the token stays even
when native association works).

- Native grouped delivery is the only transport-level association that actually works:
  peer metadata and stream ids cannot distinguish tunnels at a flat listener, so a
  flat-listener design would lean ENTIRELY on the token — and unbindable garbage streams
  (wrong/no token) could never be attributed to their tunnel for rate-limiting/teardown.
- Because grouped delivery replaces flat delivery (EINVAL when both handlers are set),
  `PortviewListener` grows a group-handler mode in which EVERY inbound tunnel arrives as a
  group; legacy bare dials arrive as single-stream groups and route down the existing
  frame/classifier path unchanged. The first-byte classifier from the design above is
  unaffected (it operates on the stream's first bytes, not on how the stream was delivered).
- Grouped delivery also gives the per-tunnel stream cap a natural home (count streams per
  delivered group) and halves the dead-delivery bookkeeping (Q3).
- Lane streams stay client-opened BIDI with client half-close after the preamble (Q4
  confirms host→client flow survives the client FIN). Unidirectional streams work (phase-2
  option confirmed viable) but stay out of phase 1 per the review fold.

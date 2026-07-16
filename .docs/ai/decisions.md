# Decisions

> Architecture decision records. Append-only — one entry per decision.

## [2026-07-16] Blank-screen debugging: codec dims are a full-path invariant; never cancel a never-ready inbound QUIC stream (ACCEPTED)

**Context**: first real product test on the new machine — phone connected but showed a black
screen, then (after fix 1) video froze at ~7-10s. Systematic-debugging session; three distinct
bugs, two fixed here, one localized to the phone.

1. **Even encoder dims are a FULL-PATH invariant, not a crop-path nicety** (`dd805e2`). The crop
   path (`cropOutputSize`) always clamped even "for the codec"; the full-display path passed the
   display size through raw. First odd-height display this code ever met — the notch MacBook
   built-in, logical 1800×1169 — made HEVC's BGRA→4:2:0 pixel transfer reject EVERY frame
   (kVTPixelTransferNotSupportedErr, -12905); `pumpVideo` nil'd + rebuilt the encoder per frame
   (~3000/20s), silently after seq 0 → the host sent ZERO video ever. Fix floors to even in
   `outputSize` (never exceeds the display, mirrors the crop path's semantics). Proven by a
   local VT repro (odd → -12905, even → OK) before the fix; device-verified 56fps after.
   COROLLARY: yesterday's "audio starves video" fix (0a95fb6) was chasing THIS bug's symptom —
   audio+control flowed while video was structurally absent. The starvation bug was real (its
   tests stand) but was not yesterday's black screen.
2. **The lane accept path must never cancel a never-ready inbound stream** (`e5d7f2f`). The
   iPhone's QUIC tunnel carries an extra stream that never sends a byte (origin unidentified —
   nw-internal artifact suspected; loopback macOS dials don't produce it). The 5s preamble
   deadline cancelled it; Network.framework cascaded the cancel into "Socket is not connected"
   across the whole shared tunnel ~1.3s later, killing the LIVE 56fps session (comment claimed
   "closes THIS STREAM ONLY" — false in practice). Zero-byte streams are now PARKED (first
   preamble byte awaited with no deadline): they cost nothing until bytes arrive, QUIC stream
   caps bound the count, and they die with the tunnel. The deadline still bounds PARTIAL
   preambles — the real slow-loris surface. Loopback regression test added; the cascade itself
   is not loopback-reproducible, so the production nw-log signature (cancel at +5.08s ≈ the 5s
   deadline → group failure) is the confirming evidence.
3. **Host exonerated for the residual ~7-10s freeze** — a headless probe (scratch SwiftPM pkg
   dialing `PortviewClientSession` like the phone: tunnel + primary, v1 hello, feedback piggyback)
   streamed 90s / 5022 frames / 0 gaps from the live host. Phone runs the Jul 10-11 client (no
   way to have installed anything newer — devicectl never paired to this Mac), which predates the
   audio-starving fix; steady ~50 pkt/s audio (SCK emits silence buffers) rides its lossless
   control lane ahead of video. Next step is a cable install + retest, NOT more host work.

**Context**: first session on a new machine (beads DB / memory / Keychain identity did not travel);
baseline re-verified green, then the remaining fleet queue was drained (djx review + fixes, 8z9,
e00, s86) — 6 commits. Load-bearing decisions:

1. **A transient keychain failure must never rotate the persistent host identity.** Chasing a
   test flake exposed that `TLSIdentity.loadOrCreatePersistent` collapsed "record absent" and
   "read THREW" into one `try?` — one securityd hiccup at launch minted a fresh identity AND
   overwrote the stored record, breaking every client's saved pin. Semantics now: thrown read →
   ephemeral session identity, store untouched (next launch recovers); decode-corrupt/expired →
   overwrite-mint (the self-heal, unchanged); import gets one retry before self-heal. The
   real-keychain test skips the degraded outcome rather than flaking.
2. **Re-wake hardening architecture (8n1.3 adversarial review, bead djx)**: (a) `ReWakeDeadline`
   resumes AT the deadline via a first-resume-wins continuation race — a task-group race awaits
   all children, so one non-cancellation-cooperative CloudKit call starved the silent-push
   completion handler past the ~30 s watchdog (the review's headline; CK fetch is now also
   cancellation-cooperative via `operation.cancel()`). (b) Pushes are CHAINED (the e00/beacon
   pattern client-side) and every handler save is a narrow read-modify-write; the change token
   persists only after the whole batch (mid-batch kill → refetch + epoch dedupe). (c) One-shot
   flags burn only after their effect RESOLVES (auth prompt) or is actually visible (denied
   hint). (d) App state is read at routing time, and a live session suppresses only its OWN
   host's wake — a different Mac's wake posts a banner (`willPresent` shows re-wake alerts).
3. **Machine-handoff reseed convention**: beads re-filed from the git-tracked docs under a new
   `portview-*` prefix (old `screenshare-*` ids kept in descriptions); deliberate-untriage rules
   re-applied. GOTCHA: `bd init` auto-COMMITS `.beads/` despite the stealth convention — the
   commit was excised (rebase) and `.beads/` is excluded via `.git/info/exclude` on this machine
   (repo `.gitignore` deliberately untouched). A git operation that removes tracked `.beads`
   files deletes bd's config from disk — restore `config.yaml`/`metadata.json` from the dropped
   commit, the dolt data dir survives untracked.
4. **jc3 ("auto/pinned mapping pin") was NOT reconstructed** — its description existed only in
   the lost DB and every plausible reading is already test-covered; the bead carries the analysis
   and waits for the user to restate intent rather than shipping guessed scope.

## [2026-07-10] Fleet session: injectable-seam test policy, outbound-lane ownership, lanes landed DORMANT (ACCEPTED)

**Context**: Fable fleet session executed 16 beads (waves: vs9/627/8n1.1/480/42r → w6n.1/w6n.2/90p/b1l
→ w6n.3/8bm → w6n.4/w6n.5 + xgy → cqv.4/cqv.5, plus the 57u live-input incident bead), every bead
adversarially reviewed, all review findings fixed before close. Load-bearing decisions beyond
commit messages:

1. **Tests must never touch live system surfaces — injectable seams are policy, not preference.**
   `InputInjectorGateTests` typed "hi"+Return into the user's focused app on every `swift test`
   run: the dev terminal holds Accessibility, so CGEvent `.post()` from tests is LIVE — the
   "posting is inert without permission" assumption was false, and the test's seam (`didInject`)
   observed the effect instead of interposing it. All CGEvent posting now exits via
   `InputInjector.postEvent` (default = real HID post; tests stub it), and the rule generalizes:
   any live surface (CGEvent, NSPasteboard, audible audio, IOPM) gets a seam AT the effect
   boundary (KeepAwake's backend was the precedent). `bd remember` key: test-live-side-effects.
2. **One session-owned ordered outbound lane (bead 8bm)**: `OutboundLane` (ordered single-drain,
   coalescing keys, injectable sink) owned by `serveSession`, finished in its teardown defer;
   clipboard/broadcast/file sends ride it (no fire-and-forget `Task { send }` survives).
   **Back-pressure over queuing for bulk**: `send(_:)` suspends until the sink ran, so file
   transfers keep strict order while at most ONE 64 KiB chunk ever sits between two control
   messages (the review showed order-vs-latency were re-coupled by naive serialization).
   `disconnectAll` deliberately stays direct — the teardown path must sequence close after the
   bye send, and the lane has no completion hook for its own owner's death.
3. **ReWake state separation (bead 8n1.1 review)**: beacon epochs are the HOST's opaque ordering
   values (dedupe/replay only — spec permits counters); "when did this client last act" is
   separate client-clock state (`lastActedAt`). Deriving act-times from epochs made the rate
   limit inert for counter epochs. Contract for 8n1.2/8n1.3:
   `evaluate(beacon:savedHosts:lastHandledEpochs:lastActedAt:now:)` — caller persists both maps.
4. **`AsyncGate` serializes CaptureEngine config updates (bead 480 review)**: `setViewport` and
   `setMaxFPS` both run mutate→`await updateConfiguration`→rollback on the SAME config object;
   `NSLock` can't span the await and actors are reentrant at suspension points, so a small FIFO
   continuation-based mutex guards the critical sections. Interim until the planned full actor
   conversion of CaptureEngine.
5. **QUIC lanes landed end-to-end but DORMANT (epic w6n phase 1)**: stream-tunnel association via
   `NWListener.newConnectionGroupHandler` (spike-proven: a flat listener cannot associate —
   peer identities compare equal across tunnels, stream ids collide; grouped delivery REPLACES
   flat, legacy dials arrive as single-stream groups); first-byte classifier with the invariant
   "no legitimate first frame has bodyLength ≤ 6" (golden-guarded); per-tunnel allowance
   16 bidi/4 uni budgeting 2× for the spike-pinned double-delivery quirk.
   **`ProtocolVersion.current` deliberately stays 1**: activating lanes before ANY on-device
   verification would put an unverified transport under all 12 pending device-verify beads. The
   one-line bump (current → laneVersion) is the A/B lever for `w6n.6`, recorded on that bead.
   **Flip contract**: a dead lane redirects sends within the SAME pumpVideo (keyframe via the
   capture-request path) and must NEVER restart the pump — the client `StaleVideoGuard` depends
   on it; its cross-source staleness is two-axis (sequence OR capture PTS, the PTS axis being
   what recovers a pump restart landing inside a flip window).
6. **Token-compare hygiene deferred**: lane session-token comparison is plain (marked in-code);
   constant-time compare + never-log discipline belongs to the dedicated security session with
   the 1nt track (standing rule).

## [2026-07-08] bd metadata is the canonical triage home + deliberate-untriage convention + next waves filed (ACCEPTED)

**Context**: Fable planning day (no code). Audit finding: **zero** beads in the database carried
Conductor-readable triage fields — every `tier_floor`/`complexity`/`verify_cmd` lived in
description prose, which Conductor never parses (per AGENTS.md: description ⇒ Untriaged, fail
closed). Past fleet sessions worked only because Fable ran them in-session. Decisions:

1. **bd `--set-metadata` is now the canonical home** for `tier_floor`/`complexity`/`verify_cmd`
   on every dispatchable bead (12 swept this session; all new beads filed with it). Description
   prose keeps a human-readable copy but is no longer load-bearing.
2. **Deliberate untriage is the dispatch gate.** Conductor's fail-closed Untriaged behavior is
   used ON PURPOSE to keep non-fleet work out of cycles: device-verify beads (human+hardware),
   the security track (1nt/7jl/5yw/9m2 — dedicated security session only, standing rule),
   `10p` (phase 2, needs its own spec), `cqv.2` (Apple-account-gated), `l4y` (needs user product
   decisions), `2ws` (scope undefined until device feedback) carry **no `verify_cmd` metadata**.
   Do not "helpfully" triage these; that would arm them for headless dispatch.
3. **Next waves decomposed from the 2026-07-01 specs** (specs unchanged, faithfully transcribed):
   CloudKit re-wake → epic `screenshare-8n1` (.1 pure core → .2 host + .3 client → .4 device-verify);
   QUIC lane-splitting phase 1 → epic `screenshare-w6n` (.1 spike + .2 proto → .3 transport →
   .4 host + .5 client → .6 Tailscale A/B), all gated on `vs9` per the spec (350 landed).
   `screenshare-10p` demoted to the phase-2 per-frame-streams bead, blocked by `w6n.6`
   measurements — the original monolith title promised phase-2 scope phase 1 never delivers.
4. **Epic hygiene**: `1n6` closed (7/7 children landed); `ux7` rewritten as an index-only bead.
   Every reference cited in new beads was adversarially re-verified against the live tree by a
   4-agent workflow before this entry (corrections, if any, applied to the beads directly).

## [2026-07-02 #2] P0 wire hardening SHIPPED + inbound-backpressure design (ACCEPTED)

**Context**: The fleet-execution session implemented the P0 cluster from the entry below
(18 beads landed; see git log 7c5042e..be6edb0). Two design decisions made in flight are
worth recording beyond commit messages:

1. **`Frame.maxBodyLength` = 16 MiB** (wire ceiling, beads 1n6.1/1n6.2). Rationale: ~8× the
   largest legitimate frame (multi-MB HEVC keyframes at 80 Mbps), 256× the 64 KiB file chunk,
   and it bounds worst-case pre-auth decoder memory at 256 MiB across the 16-connection serve
   cap. **Consequence**: clipboard text is sent uncapped, so a >16 MiB copy now drops the
   session — sender-side cap filed as `screenshare-2nn` (P3). Checked in UInt64 space BEFORE
   any `Int()` conversion at all three decode surfaces; `readBytes` bounds check rewritten in
   subtraction form (`count <= storage.count - offset`) against addition-overflow traps.
2. **Two-lane in-process inbound buffer over a lane split or stream policies** (bead 523.5).
   `PortviewConnection.inbound` stays `AsyncStream<AnyMessage>` via `AsyncStream(unfolding:)`
   pulling from `InboundBuffer`: control = lossless FIFO whose buffered payload bytes gate the
   receive re-arm (4 MiB high / 1 MiB low hysteresis → the paused receive fills the QUIC
   window → real end-to-end pushback, which a newest-N policy alone cannot give for file
   transfers); video = newest-2 coalesce (mirrors `CaptureEngine.bufferingNewest(2)`; drops
   surface as `ClientFeedback.droppedFrames` sequence gaps). Rejected: `AsyncStream` buffering
   policies (producers never suspend; would drop control) and doing the QUIC lane split now
   (pre-empts the lane spec — this buffer IS the lane taxonomy enforced in-process until the
   split lands at stream level). Re-arm decisions use the enqueue call's own verdict, never a
   flag re-read (consumer-clear race would double-arm the receive loop).
   Related (bead 523.4): `HostRunner.MessageReader` now owns the inbound iterator for the
   connection's lifetime with a memoized `pendingRead` — a timed-out read is re-awaited, never
   abandoned, so `AsyncStream`'s fatal two-consumer case is unreachable by construction.

## [2026-07-02] Fresh re-review confirmation + wire-decoder P0 hardening + 3 lead specs folded (PROPOSED)

**Context**: Follow-up to the 2026-07-01 arch-review ADR below. A fresh, independent six-lens
re-review (concurrency / protocol-wire / media / security / boundaries / prod-readiness) ran
post-wave-2 to (a) re-test the morning findings against the current tree and (b) surface
anything the first pass missed, ahead of decomposing the remaining roadmap into a
fleet-dispatchable beads backlog. Two lead specs (CloudKit re-wake, QUIC lane-splitting) were
authored and design-reviewed in the same arc; a third (mutual auth) was authored and carries
one open enrollment decision. All file:line refs below were re-verified against source
2026-07-02.

**The re-review CONFIRMED the five 2026-07-01 findings** and surfaced **one net-new CRITICAL
the morning review missed**, plus two confirmed DoS surfaces on the same wire path:

1. **NET-NEW CRITICAL — unauthenticated ~10-byte pre-auth remote crash.** `Int(bodyLength)`
   where `bodyLength: UInt64` comes from `reader.varUInt()` (full 0…2⁶⁴-1 range) traps
   *uncatchably* on any value > `Int.max`. A peer sends a 10-byte length prefix encoding e.g.
   `0xFFFFFFFFFFFFFFFF` and the whole host process aborts — Swift's overflow trap is a fatal
   error, NOT a catchable `Error`, so `processIncoming`'s do/catch cannot save it. Reachable
   **pre-authentication** (the SAS preamble uses an unpinned TOFU connection; the receive loop
   starts on every accepted connection). Triple-confirmed shape: `FrameDecoder.swift:20` (also
   :23, :29 in the same `push()`), `Frame.swift:54` (`Frame.decode`), and
   `BinaryReader.swift:58` (`data()` → `readBytes(Int(n))`) plus `:51` (`offset + count`
   Int-addition overflow in `readBytes`). No test feeds a length > `Int.max`; no ceiling
   constant exists anywhere in `Sources/`.
2. **Confirmed pre-auth memory-exhaustion DoS.** `FrameDecoder.buffer` (`:3`) grows unbounded
   via `buffer.append(contentsOf:)` (`:8`); there is no cap on buffered bytes or on a single
   declared `bodyLength`. A peer that never completes a frame (or declares a huge body below
   2⁶³) grows host memory until OOM-kill; combined with the 16-slot serve cap a few peers
   suffice.
3. **Confirmed no-backpressure inbound stream.** The per-connection inbound
   `AsyncStream<AnyMessage>` is `.unbounded` (`PortholeConnection.swift:32`, `makeStream()`
   default) and `receiveNext()` re-arms immediately, so QUIC flow control never engages and a
   stalled consumer buffers full copies of 60fps HEVC frames without bound (no drop-to-latest).

**Decision — harden the wire decoder (P0), extending epic `screenshare-1n6` (wire-safety):**
Introduce a `MAX_FRAME_LENGTH` ceiling checked in **UInt64 space BEFORE any `Int(...)`
conversion** (throw `WireError.malformed`, the existing case; mirror the
`skipsUnknownTagWithoutWedging` test pattern in `FrameDecoderTests`); bound the
`FrameDecoder` buffer + per-frame body (close the connection past the cap); and give the
inbound path a bounded/newest-N policy for the video lane (mirror `CaptureEngine`'s
`.bufferingNewest(2)`). Fix `readBytes` to compare `count <= storage.count - offset`
(subtraction, no addition overflow). This is a **P0 hardening cluster** — the crash is a
pre-auth remote DoS on the current wire, above all M6 feature work.

**The two new specs are SOUND-WITH-FIXES** after folding the design-review must-fixes
(2026-07-02): `docs/superpowers/specs/2026-07-01-cloudkit-rewake.md` (epoch must be wall-clock
not host-uptime — the `HostRunner.swift:534` uptime idiom regresses on reboot and silently
eats wakes; full iOS silent-push plumbing enumerated — none exists today; host owns
`PortviewSignals` zone creation; per-host `lastHandledEpochs` map) and
`docs/superpowers/specs/2026-07-01-quic-lane-splitting.md` (host-minted token rides
`ServerHello` not client→host `StartSession`; lane streams must be bidirectional; explicit
first-byte stream classifier; per-tunnel stream cap; forced keyframe on lane flip; `Lane`
gains a `stats` case; `VideoFrame` already carries `sequence`). Both fold-sets are plain
platform/protocol/Network.framework work.

**Mutual-auth spec** (`docs/superpowers/specs/2026-07-01-revocable-pairing-mutual-auth.md`,
gating `screenshare-7jl`) is authored and its signed-challenge core reviewed sound, but **one
load-bearing enrollment-trust decision remains OPEN** (whether SAS-match alone may enroll a
device key, or the host must one-tap confirm / bind the pubkey into the SAS transcript). That
decision is deferred to a dedicated security-review pass and captured in the spec's "Open
review pass" section; `screenshare-7jl` stays OPEN and `t-authgate` blocked on it — NOT
resolved here.

**Backlog**: this ADR is implemented by a new P0 wire-hardening cluster under `screenshare-1n6`
plus concurrency/media/client beads across `screenshare-523`/`ja1`/`jfj` and a NEW
"prod/open-source release readiness" epic (hardcoded `DEVELOPMENT_TEAM` K7CBQW6MPG + `dev.finklea`
bundle IDs, no notarization/install path, no versioning/TestFlight readiness, `print()`-only
logging on the host, missing `SECURITY.md`/privacy-manifest/build-prereqs). All findings are
code-cited and were verified against source before filing.

**Why PROPOSED**: same reasoning as 2026-07-01 — the P0 wire-hardening beads are safe to start
immediately (pure decoder robustness, TDD, no protocol reshape); the spec-gated epics await the
user's review of the specs.

## [2026-07-01] Architecture review — five decision clusters + fleet backlog (PROPOSED)

**Context**: Fable 5 ran a six-lens adversarial architecture review (concurrency / wire-protocol / media / security / module-boundaries / roadmap-fit) to break the roadmap into work cheaper fleet models (Sonnet 5, GPT-5.5, open-source) can execute. Full synthesis: `.docs/ai/phases/arch-review-2026-07-01-report.md`. Findings are code-cited; every critical/high was independently refuted before acceptance.

**The five load-bearing findings** (all verified against the real code, several by hand):
1. **Unknown wire tags silently, permanently wedge the connection** — `Frame.decodeBody` throws before `FrameDecoder` consumes the frame; `PortholeConnection.receiveNext` swallows via `try?`; inbound stream never finishes → infinite re-throw, unbounded buffer. So adding ANY new tag (new client vs old host) is a session-killing break TODAY. This makes "skip unknown tags" the dependency ROOT of all new-message work.
2. **Host authenticates no client (critical)** — `QUICParameters.server` sets only a local identity; `serveSession` grants full control to any peer completing a bare `ClientHello`; the pin is client-side-only and the SAS window is never checked on the streaming path. The unbuilt M6 "device keypairs + revocable PairingStore" is the fix.
3. **Locked-screen input gate is client-side only (critical)** — `InputInjector.handle` posts CGEvents unconditionally; a modified client injects into a locked Mac. Cheap host-side fix.
4. **M6 features share one missing foundation** — adaptive bitrate, latency harness, and lip-sync all need infrastructure that doesn't exist: live encoder-bitrate setter (bitrate is init-only → forces the crash-adjacent rebuild), client→host feedback, RTT/clock primitive, presentation clock. Build the keystone once.
5. **Client has no testable core; two 750-line god files; a real `CaptureEngine.config`/`stream` data race; serve-slot starvation.** `PortviewClientCore` is the highest-leverage Lead extraction (lowers the tier_floor of all client work + unblocks CI).

**Decisions (PROPOSED — to ratify)**:
- **A** Wire evolution: unknown tags MUST skip not wedge; thread + use the negotiated version; golden-frame KAT + reserved tag ranges as regression gates. EPIC `screenshare-1n6`.
- **B** Host authenticates clients via device keypairs + a revocable keychain-backed PairingStore, verified before any scaffolding; lock gate + file/clipboard caps host-side. Lead-tier spec first. EPIC `screenshare-1nt`.
- **C** Real-time media rides one keystone (Ping/Pong RTT + live `setAverageBitRate` + client→host feedback), then adaptive bitrate / presentation clock / PTS lip-sync. EPIC `screenshare-ja1`.
- **D** Stand up `PortviewClientCore` once, then decompose the god files as pure value types; local `make preflight` pre-push gate (no reliable hosted macOS-26 runner); GlassTheme stays per-app. EPIC `screenshare-jfj`.
- **E** Fix the CaptureEngine data race + serve-slot starvation; move toward actor isolation + a session-owned host outbound lane. EPIC `screenshare-523`.

**User decisions (2026-07-01)**: threat model = local LAN / Tailscale / WireGuard → mutual-auth is P1 (not P0), but a real exposure on untrusted LAN. Re-wake = CloudKit silent push (own iCloud, no hosted server) → spec `screenshare-8qi`. Fleet does all four clusters + forward planning.

**Backlog**: 35 new beads (5 epics + 30 tasks) with a verified 20-edge dependency graph (no cycles), all machine-verifiable; device-observable effects are separate human-gated follow-ups. Enriched `vs9`/`ins`/`10p`/`627` to dispatchable specs; closed `8ds` (already done — `OutboundInputPump`). `bd ready` surfaces the roots; `w-skip` (kyf) and `cc-target` (1j0) are the two keystones to do first.

**Why PROPOSED not ratified**: the decisions reshape the wire protocol, trust model, and module layout — the user should review the report before the fleet executes the XL/lead-tier items. The P0/P1 machine-verifiable roots (w-skip, w-golden, cc-target, t-lockgate, t-filecap, x-capturerace) are safe to start immediately.

## [2026-06-28] Host — keep-awake + host-lock status (the achievable slice of "work on a locked screen")

**Context**: User asked to make Portview "work on a locked screen / unlock it." The 2026-06-28 feasibility spike (phases/locked-screen-feasibility-report.md) established the real locked/login/unlock case is walled off (secure event input, first-party-only privileged path, TCC can't bootstrap without a logged-in user). The achievable, worthwhile slice: keep the Mac from idle-locking mid-session, and tell the client when the host IS locked so it pauses instead of showing a black frame.

**Decision**:
- **KeepAwake** (PortviewHostCore): holds a system keep-awake assertion for EXACTLY the span when ≥1 streaming session is active. Keyed by a `Set<String>` of session ids (NOT a bare counter) so `disconnectAll` clearing sessions out from under the per-connection teardown can't strand it (a late `sessionEnded` for an already-removed id is a no-op). Wired into `HostControl.register/deregister/disconnectAll`. Two assertions: `kIOPMAssertionTypePreventUserIdleDisplaySleep` (keeps the screen lit so the viewer keeps seeing content) + a periodic `IOPMAssertionDeclareUserActivity` re-arm — the display-sleep assertion ALONE does NOT stop the screensaver/idle-lock (verified in the design research), so the re-arm is what actually suppresses the idle lock. Backend AND ticker are injectable (`KeepAwakeBackend`, `KeepAwakeTicker`) so transitions + the periodic re-arm are tested deterministically without IOKit or wall-clock timers.
- **LockMonitor** (PortviewHostCore): seeds the authoritative state from `CGSessionCopyCurrentDictionary` (silently — no startup transition), then forwards live `com.apple.screenIsLocked`/`screenIsUnlocked` distributed notifications (non-sandboxed only; undocumented but long-stable — backed by the CGSession seed, never gating security). `HostRunner.run` broadcasts a new `HostLockStatus(locked:)` (tag 26) on change; each client is ALSO seeded the current state at handshake (so one connecting while locked pauses at once).
- **Client**: `hostLocked` published state → "capture paused" overlay; `inputPaused` gates EVERY input send (pointer/click/scroll/text/key) — not just the trackpad's hit-testing — and `hostLocked` is reset per stream attempt so a reconnect after the host unlocked can't strand the overlay.

**Why the QoS bump**: the re-arm timer is deadline-sensitive (must fire well under the ~60s screensaver threshold); `.utility` QoS coalesces/defers too aggressively (caught when the timing test only saw the immediate kick), so the dispatch ticker uses `.default` QoS with ~10% leeway.

**Process (ultracode)**: design/mapping workflow (3 codebase mappers + 1 macOS-best-practices researcher) → TDD per layer → adversarial review workflow (5 lenses → per-finding refutation, 21 agents). Review surfaced 7 real findings (2 functional: client input bypassed the lock gate; `hostLocked` stranded across reconnect) — all fixed; the rest refuted (e.g. "lock overlay leaks the lock screen" — false: the secure desktop isn't capturable, frames are blank/black).

**Verify**: `swift test` **183** (HostLockStatus ×4, KeepAwake ×10, LockMonitor ×3), macOS host BUILD SUCCEEDED, iOS `xcodebuild test` **57**. Reviewed (adversarial workflow) — no surviving findings after fixes. NOT pushed. **Device-verify**: idle past the display-sleep/screensaver timeout with a client connected → stays awake, doesn't idle-lock; manual lock → client overlay + input disabled; unlock → resumes.

## [2026-06-27] Host — runtime display refresh (multi-monitor switcher without relaunch)

**Context**: The host snapshotted `SCShareableContent.current.displays` ONCE at launch and shared it (immutable `SendableDisplays`) with every connection. A monitor connected/woken after launch never appeared, so the client's display switcher (gated on `displays.count > 1`) stayed hidden until a full host relaunch. Surfaced when the user relaunched the host with the 2nd display asleep and "lost the ability to change monitors."

**Decision**: Make the display list live and push changes to connected clients.
- **Protocol**: new `DisplaysUpdate` message (tag 25), host→client, carrying `[DisplayInfo]` — the same payload `ServerHello` already carries, but sendable on its own whenever the set changes.
- **Host**: `DisplayRegistry` (lock-guarded `@unchecked Sendable`) replaces `SendableDisplays` as the shared display source; the handshake `ServerHello` and `switchDisplay(forID:)` read it live. `refreshDisplaysLoop` polls `SCShareableContent.current` every 2s (the same source as the launch snapshot) and, when `displaysChanged` (order-independent set compare, sensitive to id/count/dims) is true, updates the registry and `HostControl.broadcast`s a `DisplaysUpdate`. The loop runs alongside `serveConnections` in a `withTaskGroup` under the existing cancellation handler (cancel → `listener.cancel()` ends the connections stream → `group.next()` returns → `cancelAll()` stops the poll). An empty snapshot is ignored so a transient read can't blank the registry.
- **Client**: `.displaysUpdate` updates `session.displays` (switcher reappears). `resolvedActiveDisplay(current:among:)` keeps the streamed display if still offered, else falls back to the first AND retargets the host via `switchDisplay` (so the stream isn't stranded on a removed display); a resolution change on the active display updates `displaySize`.

**Why polling, not `NSApplication.didChangeScreenParametersNotification`**: keeps `PortviewHostCore` decoupled from AppKit (it's a library used by both the app and the CLI), and `SCShareableContent.current` is the authoritative source already trusted at launch. 2s matches the app's existing permission poll cadence; the cost is negligible.

**Why broadcast only reaches streaming sessions**: SAS-preamble connections are never registered in `HostControl` (separate `serveSASPreamble` path), so a `DisplaysUpdate` can't leak onto an unpinned preamble connection — it only carries SAS messages.

**Verify**: `swift test` **166** (`DisplaysUpdateTests` ×3, `DisplayRefreshTests` ×5), macOS host BUILD SUCCEEDED, iOS `xcodebuild test` **57** (`GlassMappingTests` +3 `resolvedActiveDisplay`). The iOS 26.0.1 sim runtime disk image was present but had no simulator device — recreated an iPhone-17 device, then the full iOS suite ran green; client also builds + installs on Roshar. Reviewed clean (native code-reviewer: teardown, registry thread-safety, broadcast-vs-video-send concurrency, serverHello-before-displaysUpdate ordering all verified; no issues ≥80). NOT pushed. **Device-verify**: connect with one monitor → wake/plug a 2nd mid-session → switcher reappears within ~2s, no relaunch; switching to it works.

## [2026-06-26] Zoom — low fps at high zoom: edge-hysteresis re-cropping

**Context**: After capture-time tagging, the residual "flash" was confirmed (device) to happen ONLY on MOVING content, never static. Frame analysis of a moving-content clip: at 6× the stream was **1.5 Mbps · ~4 fps**. The smooth display-link pan can't hide a 4 fps *content* stream → moving content looks choppy/flashy; static has nothing to update so looks fine.

**Root cause (confirmed by experiment)**: at a fixed zoom, every pan step makes the host call `SCStream.updateConfiguration` to move `sourceRect` (~6.6×/s at the 150ms throttle), and updateConfiguration hiccups SCK frame delivery → ~4 fps while panning. Diagnostic: bumping the throttle to 400ms → fps rose (confirms updateConfiguration is the bottleneck) but introduced a laggy "doesn't paint until a second after I move to the new region" (the blunt throttle delays the *needed* re-crop too).

**Decision**: **edge-hysteresis re-cropping** (`SessionViewModel.requestViewport(crop:window:)` + pure `windowCovered`). Re-crop ONLY when the visible window isn't already covered by the region the host is sending (`frameViewport`): it must be inside by a margin on every side (a side flush with the display boundary needs no margin — can't capture past the screen) AND the crop not be >2.5× the window. So in-region pans don't re-crop (fps stays high) while a move to a new region re-crops promptly (the throttle's leading edge, back at 150ms, fires it immediately → paints fast). Gets BOTH high fps and fast paint, unlike the blunt throttle.

**Bug caught pre-device (by the unit tests)**: margin was first absolute (0.05) but the crop padding is relative (0.25×window) — at high zoom the window's padding (e.g. 0.025) < margin → a fresh crop read as "not covered" → would re-crop EVERY frame (a loop). Fixed: margin is a fraction of the window (`marginFraction 0.12` < the 0.25 padding) → scale-invariant.

**Verify**: iOS `xcodebuild test` **54** (new `ViewportHysteresisTests`: in-region covered, near-edge re-crops, display-edge-no-margin, initial-zoom-in re-crops, fresh-crop covered, scale-invariance). NOT pushed. **Device-verify**: high zoom + panning on MOVING content should now be high-fps AND paint promptly on region changes. If fps still dips on fast cross-screen pans, raise the crop padding (more headroom, trades crispness) — tunable.

## [2026-06-26] Zoom — capture-time frame tagging (kills the re-crop "wrong-content flash")

**Context**: With the smooth-pan fix landed (device-confirmed: "so much better… a lot smoother… mouse really smooth"), the last artifact was the picture "flashing wrong content" when it repaints at the screen edge. User characterized it as a jump/flash (not a smear) → the deferred **#5 capture-vs-encode tag skew**.

**Root cause**: the host tagged each `VideoFrame` with `capture.currentViewport()` at ENCODE time, but the pixels were captured ≤2 frames earlier (the `.bufferingNewest(2)` queue) under a possibly-different crop. On a re-crop the client mapped the zoom window into the NEW region while the pixels were still the OLD region → wrong-content flash, worst at edges where the crop reshapes.

**Decision**: Tag at CAPTURE time. `SendableFrame` carries a `region`, snapshotted in the SCStream `didOutputSampleBuffer` callback from `appliedRegion` (a lock-guarded copy set when `updateConfiguration` takes effect). `pumpVideo` tags the wire frame from `frame.region` instead of the live `currentViewport()`. So a buffer captured under the old crop but encoded after a re-crop carries the OLD region → the client always maps the window into the region the pixels actually show. **Host-side only** (the client already maps into the frame's region); does NOT touch the capture-size ladder → can't reintroduce the crash. Residual: the `updateConfiguration`→first-new-buffer latency is inherent and small (was the dominant queue+encode skew, now removed).

**Verify**: `swift test` 158, macOS BUILD SUCCEEDED. NOT pushed. **Device-verify** (needs the rebuilt host relaunched): pan to the screen edge while zoomed → no wrong-content flash on the re-crop.

## [2026-06-24] Zoom smooth-pan — display-link eased render loop (the actual fix)

**Context**: Device test of Phase C: tearing stayed gone but the pan was "even jerkier than before." Systematic-debugging + two diagnostic questions to the user localized it precisely: **jerky ONLY when panning, smooth when still, smooth at zoom 1** → the base stream is fine; it's purely the cursor-follow pan.

**Root cause (evidence-backed)**: Phase A's pan was a SwiftUI spring on a CA transform — Core Animation interpolated it every display refresh (smooth, decoupled from video fps). Phase C moved zoom in-shader but made the window update **only when a video frame arrived, with no interpolation** → the pan stepped at video-frame rate and exposed the cursor's per-update jitter. Strictly *less* smoothing than A → jerkier.

**Decision**: Keep the in-shader zoom (no tear, no re-crop jump, crisp) but **drive rendering from a `CADisplayLink` and ease the window toward the cursor at display rate** — restoring A's smooth follow without A's CA transform. Concretely: `ZoomGeometry` now emits `visibleWindow` (display-normalized; no `frameViewport` param — the f-dependent mapping moved out). The renderer holds `targetWindow`/`currentWindow`/`lastPixelBuffer`/`latestFrameRegion`; `submit(buffer, region)` stores the newest frame; `tick()` (per vsync) eases `currentWindow`→`targetWindow`, maps it into the latest frame's region (`sampleRect(window:in:)`), and draws — so the pan is smooth at 120 Hz even if video arrives at 30 fps, and re-crops still don't move the on-screen window. `SessionViewModel` pushes `targetWindow` on cursor/zoom changes and `submit`s each frame; `MetalVideoUIView` owns the display link. Easing is **time-normalized** (`perTickFactor`) so 60/120 Hz feel the same; window is **snapped** (not eased) on a display switch.

**Process**: systematic-debugging (no fix without root cause) → user diagnostic answers → implement → native adversarial review (SHIP-WITH-FIXES; verified no frame-drop, no race, zoom-1 + no-jump invariants hold). 2 review fixes applied: refresh-rate-independent easing (#4 — Roshar is 120 Hz ProMotion) and snap-on-display-switch (#3). Deferred (review, minor): pause the display link at true idle (small power), capture-time frame tagging.

**Verify**: iOS `xcodebuild test` **47** (new `MetalVideoRendererTests`: no-jump invariant, easing-settles, window-past-frame; `ZoomGeometryTests` updated to `visibleWindow`). NOT pushed. **Device-verify**: zoomed pan should now be SMOOTH (the headline), tearing still gone, crisp; reset-zoom/display-switch cut cleanly. Easing feel tunable via `MetalVideoRenderer.easingFactor` (0.28; lower = smoother/laggier).

## [2026-06-22] Zoom tearing + repaint glitches — Phase A (present-sync) landed; Phase C (in-shader zoom) queued

**Context**: First on-device test of the magnifier stack. Result: **no crash** (the rapid-zoom landmine is cleared on hardware ✅), crispness "usable", look/persistence good. New report: **screen tearing + repaint glitches when zoomed in**. Diagnosed via an ultracode workflow (3 code lenses + a web-research lens → synthesis).

**Root causes (ranked)**: (1, high) the CAMetalLayer presents drawables asynchronously (`commandBuffer.present(drawable); commit()`, `presentsWithTransaction=false`) while the zoom is a SwiftUI `.scaleEffect/.offset` Core-Animation transform on that same layer — new pixels composite under the previous transform for a compositor cycle → a seam/**tear** (invisible at zoom 1 where the transform is identity, amplified when zoomed). (2, high) `renderScale`/`pan` are computed THROUGH `frameViewport`, so each host re-crop (~6.6/s while panning) hard-**steps** the on-screen geometry → repaint jumps (the deferred #4; the ZoomGeometry doc comment claiming f-invariance is algebraically false — `renderScale = f.width/window.width`). (3, high) magnification is a Core-Animation **upscale of a 1×-resolution drawable** (the shader only aspect-fits the full frame), which is the accepted softness and amplifies the seam. (4/5) spring-vs-stepping + the ≤2-frame capture-vs-encode tag skew — minor, fall out of the above / deferred.

**Correction to the synthesis (verified by deriving the math)**: its "Phase B" (make `renderScale` f-invariant as a ZoomGeometry-only change) is NOT achievable in Core Animation — the CA transform scales the *whole* frame texture (which shows only region `f`), so `renderScale` must track `f` to keep the window placed. Making the on-screen scale truly f-invariant requires the **shader** to do the windowing (sample the window's UV sub-rect) = Phase C. So B and C are one fix, not two. Real decomposition: **A kills tearing; C kills the repaint-jumps + nets crispness; there is no cheap middle.**

**Decision**: 
- **Phase A — DONE (build-green; device-verify pending)**: `MetalVideoRenderer.attach` sets `presentsWithTransaction = true` + `maximumDrawableCount = 3`; `render()` now `commit(); waitUntilScheduled(); drawable.present()` (manual present on the @MainActor render path) so the present enrolls in the same CATransaction as the zoom transform → no async-vs-CA seam. Client-render-only; cannot touch the host capture-size ladder (the crash fix). Zoom-1 unchanged (identity transform, just synchronized).
- **Phase C — DONE 2026-06-22 (build-green; device-verify pending)**: device-confirmed A killed the tearing but the picture still jumped/repainted when panning (the renderScale step per re-crop). So moved the zoom INTO the Metal shader: `ZoomGeometry` now emits `sampleRect` (the visible window mapped into the CURRENT frame's region, texture UV) instead of `renderScale`/`pan`; the fragment shader samples that sub-rect into the full-res drawable (`uvRect` uniform); `LiveHUDView` dropped `.scaleEffect/.offset/.animation`. **`sampleRect` is computed per-frame in `SessionViewModel` against THAT frame's own region** (not pushed from the view via `onChange`, which lagged `render()` by a frame and would reintroduce a 1-frame jump on every re-crop — a review catch). The on-screen window is now invariant to host re-crops (a new pure test `testSampledWindowIsInvariantToFrameViewport` locks it: the display-window recovered from `(sampleRect, f)` is constant across different `f`), and sampling is at drawable resolution (crispness bonus). A fast pan past the not-yet-re-cropped frame edge-clamps (sampler `clampToEdge`) instead of pinching — `sampleRect` is NOT clamped to [0,1] so the aspect-fit keeps the window's true size (a second review catch). Reviewed SHIP-WITH-FIXES (native) → both fixes applied. Client-render-only; cannot touch the host crash ladder; zoom-1 reduces to the prior letterboxed overview (tested).
- Deferred: #5 capture-time frame tagging (separate latency item; the one host-side change, but it touches CaptureEngine/HostRunner not the size ladder).

**Also this round**: menu-bar **Quit Portview Host** added (`21a791e`, device feedback — Stop only stopped hosting).

**Verify**: iOS `xcodebuild test` 43, BUILD SUCCEEDED (Phase A is render-loop config — no unit seam; build-green is the bar). NOT pushed. Device-verify: zoomed pan should no longer tear; if repaint-jumps remain, that's Phase C.

## [2026-06-21] SAS Guardrail C — bound the connection accept loop (DoS hardening)

**Context**: `HostRunner.serveConnections` served every accepted connection in an UNBOUNDED `withTaskGroup` (one child task per connection). Flagged by the SAS reviews: a connection flood — or many SAS preambles, which now linger ~25s awaiting their Guardrail-E confirm — could spawn arbitrarily many tasks, each holding up to QUIC idle (30s) on a silent connection. Pre-existing, made more pressing by E.

**Decision**: Cap concurrently-served connections at `maxConcurrentConnections = 16` with backpressure — when `running >= maxConcurrent`, `await group.next()` reaps a finished task (freeing a slot) before adding the next, so in-flight tasks never exceed the cap and excess connections QUEUE rather than spawn unbounded tasks. Generic `serveConnections` kept testable; the production call site uses the default. 16 comfortably exceeds the legit working set (1 streaming client + transient preambles + QUIC's dead double-delivery connection) and a held slot self-frees in ≤25s (the confirm timeout) so the cap can't be permanently exhausted by slow holds. Per-source rate-limiting deferred (needs the QUIC/NAT-fuzzy resolved endpoint).

**Review**: native adversarial review — SHIP. Verified cap accounting (no off-by-one), liveness (every connection served, no drops), no deadlock/starvation (`group.next()` returns as tasks terminate; SAS path bounded by the 25s timeout), clean cancellation, and that the tests assert peak≤cap + all-served (not flaky — monotonic actor counters).

**Verify**: `swift test` **155** (new `ServeConnectionsTests`: cap-not-exceeded + strict-serialize-at-1); macOS host BUILD SUCCEEDED. NOT pushed.

## [2026-06-20] SAS Guardrail E — HMAC host-confirmation IMPLEMENTED (build-green, reviewed, device-verify pending)

**Context**: Phase-2 defense-in-depth on SAS v2 (the user asked for it, ultracode-style). E gives the host a positive, authenticated "✓ a client confirmed" signal after the user-typed code matches — it must NOT weaken the verified v2 commitment and must stay purely additive.

**Process (full ultracode arc)**: Opus authored a concrete E design → a 4-lens design-review **workflow** (crypto / MITM-interaction / lockout-DoS / impl-fit) returned **SOUND-WITH-FIXES, weakensV2=false** with 6 must-fixes → folded all 6 into the spec's "E — design-review RESOLUTIONS" section → implemented TDD → dual impl review (native **SHIP-WITH-FIXES** + glm-5.2 **SHIP-WITH-FIXES**), both fixes applied.

**The 6 design-review fixes that shaped the build** (each caught from the real code, pre-implementation): (1) `.sasConfirmed` must NOT close the SINGLE shared pairing window (the "per-user window" premise was false → a relayed confirm would be a remote window-close DoS); it sets a transient `clientConfirmed` flag only, window still closes via `.deviceConnected`/timeout/cap/stop. (2) confirm-await timeout **25 s < 30 s** QUIC idle (the held connection is realistically alive). (3) read EXACTLY ONE post-reveal message, bounded by a timeout `Task` that `connection.close()`s (→ `inbound.next()` returns nil, can't hang) — a sound substitute for the spec's task-group race; `defer`-close on all branches; no retry loop against the live secret. (4) attempt counting stays at engagement start, so a forged confirm can't suppress the cap (the v1 "suppresses lockout" wording was wrong). (5) exact MAC: `confirmKey = HKDF<SHA256>(ikm: n_c‖n_h, salt: cert, info: "Portview SAS confirm v2", 32)`, `confirmation = HMAC<SHA256>(key: confirmKey, "confirm")`; verify via `HMAC.isValidAuthenticationCode` (constant-time, never `==`); structural domain separation; frozen KAT. (6) ONE client teardown chokepoint (`teardownSAS`) closing+zeroing on all five exits; `submitSASCode` match = capture conn+secret locally → teardown without closing → best-effort confirm send + close on a DETACHED task → `start()` (so `start()`'s `task?.cancel()` can't race the in-flight confirm).

**Why E doesn't weaken v2** (both reviews verified against real code): purely additive — a confirm-less client still pairs via the pinned re-dial; the host never gates the session on a confirm (`.sasConfirmed` is a flag only); the held preamble connection still builds no clipboard/injector/capture/file (CRITICAL-3 fence intact); a MITM forging a confirm to the host yields only an inert "✓ confirmed" with no device session and can't suppress the cap (counted at engagement start). The MITM defense remains the commitment, which E doesn't touch.

**Deferred (roadmap follow-ups, both pre-existing / non-blocking)**: a host-side integration test driving `serveSASPreamble`'s confirm round-trip + bounded-await (needs a seam into the private/permission-gated host loop); Guardrail C's concurrent-preamble cap (`serveConnections` is unbounded — E lengthens each preamble task's life, mildly amplifying it).

**Verify**: `swift test` **153** (SASCode 16: +confirmation KAT/binding/last-byte/cross-replay/domain-sep), iOS **43**, macOS BUILD SUCCEEDED. NOT pushed. **Device-verify**: pair via the 6-digit code → the Mac should briefly show "✓ a client confirmed" as the phone connects. New wire message `SASClientConfirm` tag 24.

## [2026-06-20] SAS pairing v2 — IMPLEMENTED (build-green, reviewed SOUND, device-verify pending)

**Context**: Implemented the design-cleared SAS v2 commit-then-reveal pairing (spec: `docs/superpowers/specs/2026-06-19-sas-pairing-v2-commit-reveal.md`). TDD, layer by layer.

**What landed**:
- **Protocol/crypto** (`PortviewProtocol`): `SASCode` (`commit` = `SHA256(tag‖role‖cert‖nonce)`, `derive` = HKDF<SHA256> L=8 %1e6 → 6 digits, `randomNonce`), 4 wire messages tags 20–23 (`SASClientCommit`/`SASHostCommit` 32B, `SASClientReveal`/`SASHostReveal` 16B) wired through `MessageType`/`AnyMessage`/`Frame`. **Frozen KAT** = `470719` for fixed vectors (pins IKM order, raw-byte salt, info string, L=8, big-endian, %06d).
- **Transport** (`PortviewTransport`): `SASPreamblePinning` — a SEPARATE type from `CertificatePinning` (TOFU capture, `complete(true)`), `QUICParameters.clientCapturingCert`, `PortviewConnection.connectCapturingCert -> (conn, Data)`. Added the previously-missing **negative pin test** (pinned client rejects a mismatched cert).
- **Host core** (`PortviewHostCore`): `serveSession` peeks the FIRST message and role-locks — `.sasClientCommit` → `serveSASPreamble` (builds NONE of clipboard/injector/capture/file) BEFORE any scaffolding; the streaming loop refactored from `for await` to a single-iterator `while let` (no dropped/double-consumed messages). `SASAttemptLimiter` (pure, injected `now`) + `SASPairingControl` (lock-guarded holder) gate a user-opened window + window-scoped attempt cap. `HostRunnerEvent.sasCode` (never wrapped in `.message`; CLI never logs it).
- **Host app**: `HostAppModel.beginPairing/endPairing` (window + 120s timeout) + `displayedSASCode`, cleared on connect/timeout/stop; menu-bar "Pair with a 6-digit code" + code display.
- **Client app**: `SessionViewModel.beginSASPairing/submitSASCode` — runs the preamble over the capturing connection, derives the code, parks awaiting the user's typed code; on match re-dials PINNED with the captured hash (preamble connection torn down first); `SASPairingSheet` numeric entry replacing the 64-hex alert.

**Adversarial review** (security-critical): native deep reviewer (verdict SHIP) + glm-5.2 tool-enabled steelman (verdict IMPL SOUND). Both verified — against the real code — the commit-before-reveal ordering + blind-commit on both legs, verify-before-use, TOFU type-isolation + pinned re-dial, the preamble fence (no fall-through either direction), window gating + window-scoped cap, role+cert binding, and secret hygiene. 2 LOW polish items applied (don't set `displayedSASCode` after the window closed; don't flash the SAS sheet back on a late failure after cancel). See `~/.claude/model-scorecard.md` (2026-06-20).

**Verify**: `swift test` **148** (SASCode 11, SASPreamble 2, SASAttemptLimiter 6), iOS `xcodebuild test` **43**, macOS BUILD SUCCEEDED. NOT pushed. **Device-verify**: on the Mac open the menu-bar item → "Pair with a 6-digit code"; on the iPhone tap the discovered Mac → SAS sheet → type the code the Mac shows → it should connect (pinned). A wrong/mismatched code must refuse. Optional phase-2: HMAC-authenticated host confirmation (Guardrail E) — not implemented (the mandatory window-scoped cap is).

## [2026-06-19] SAS pairing v2 — commit-then-reveal redesign (design cleared SOUND, ready to implement)

**Context**: The 2026-06-19 security review returned v1 for redesign (active-MITM offline nonce grind). This is the v2 design that fixes it: `docs/superpowers/specs/2026-06-19-sas-pairing-v2-commit-reveal.md` (supersedes the v1 construction).

**Decision**: Adopt a **two-sided ZRTP-style commit-then-reveal** SAS. Both sides send `commit = SHA256("Portview SAS commit v2" ‖ role ‖ H_cert ‖ nonce)` BEFORE either reveals its 16-byte CSPRNG nonce; reveals are gated on both commits (per leg) and verified against the commit. This forces an active MITM to commit BOTH substituted nonces *blind on both legs* (the honest nonce on each leg is hidden behind the MITM's own commit), killing the offline grind — residual collapses to the intended ~1/10⁶ per human-attended attempt. The **cert hash bound INTO the commit** (not just the final code's HKDF salt) is the load-bearing keystone: it makes a forwarded commit fail the other leg's verification, forcing the MITM to mint its own commit (which the per-leg gate then blinds). Code = `HKDF<SHA256>(ikm: n_c‖n_h, salt: H_cert, info:"Portview SAS v2", L:8) % 1_000_000` (L=8 fixes v1's 2× modular bias). Plus the two isolation guardrails from the review: `SASPreamblePinning` as a SEPARATE type (TOFU unreachable from the pinned path; + a negative pin test) and a dedicated `serveSASPreamble` (constructs none of the clipboard/injector/capture/file scaffolding `serveSession` builds; first-message role-lock). Plus: user-initiated pairing window, **mandatory window-scoped attempt cap** (simple counter, K mismatches → close window — both reviewers upgraded this from optional), CSPRNG fresh-per-attempt nonces, frozen known-answer test, secret hygiene, clean pinned re-dial. 6 digits kept (the v1 bug was ordering, not length). HMAC-authenticated host confirmation is OPTIONAL phase-2. QR full-pin path unaffected + preferred.

**Adversarial verification**: authored by Opus, then attacked from two independent angles — a native deep reviewer (verdict v2 SOUND) and a glm-5.2 tool-enabled steelman (v2 SOUND). Both re-ran the MITM timeline under leg reordering/pipelining and confirmed blind-on-both-legs holds; both verified commitment hiding (2¹²⁸)/binding (2²⁵⁶)/no-reflection; both independently identified cert-in-commit as the keystone; both tested a decoupling/flicker variant and showed it stays at 1/10⁶ (human typing is the rate limiter). Convergent upgrade applied: window-scoped attempt cap → MANDATORY.

**Status**: design CLEARED for implementation (lead-tier). Implementation is a separate phase (new messages 20–23, `SASCode`/`SASPreamblePinning`/`serveSASPreamble`, client SAS sheet, host pairing window) — see the spec's Files + Tests + re-review checklist. Not yet built. See `~/.claude/model-scorecard.md` (2026-06-19).

**Verify**: N/A (design). Implementation verify = the spec's TDD plan (KAT, commit/reveal verification, negative pin test, limiter, round-trips).

## [2026-06-19] SAS pairing security review — DO NOT IMPLEMENT as specified (active-MITM grind); requires commit/reveal

**Context**: The 6-digit SAS pairing design (`docs/superpowers/specs/2026-06-15-sas-pairing-design.md`) was "design complete, awaiting human security review before implementation". Ran the review as a 4-lens adversarial pass (crypto soundness / active-MITM / replay-downgrade-DoS / impl-vs-real-code) + a glm-5.2 steelman that tried and failed to refute the crux.

**Decision: the v1 construction is BROKEN against an active MITM — return to author for a commit/reveal redesign before any implementation.** Root cause: the SAS code is a public deterministic function `f(certHash, n_c‖n_h)` (no secret input) revealed **client-nonce-first with no commitment**. An on-path attacker (cert_M to the client, cert_H captured from the host) substitutes a nonce on each leg and, knowing the host's displayed `code_H` before it must send its last nonce to the client, **grinds ~2²⁰ values offline in milliseconds** to force the client's derived code equal — no honest party is involved so the nonce-issuance limiter never fires, the user transcribes the matching code, and the pin re-dial then pins the client *to the attacker*. The spec's open-question #3 ("the uncontrollable cert salt dominates") resolves adversely: an active attacker knows BOTH cert hashes, so the salt binds the code to an identity, not a channel. More digits and host-side lockout do NOT fix it (no mismatch is ever observed; the ordering is the bug).

**Required fix**: two-sided **ZRTP-style commit-then-reveal** — both sides send `H(nonce)` (binding leaf-cert hash + role) before either reveals; reveals gated on both commits per leg and checked against the commitment. Must be on BOTH legs (one-sided lets the MITM pipeline the independent legs). Then 6 digits gives the intended 1/1e6. Plus two structural guardrails the existing test suite would NOT catch: (CRITICAL-2) type-level-isolate the TOFU `installCapturing` so it can never reach the pinned streaming path (separate type, distinct connect API, not a `Bool` flag; add a negative pin test); (CRITICAL-3) a separate `serveSASPreamble` that builds none of the clipboard/injector/capture/file scaffolding `serveSession` instantiates before its switch — else an UNPINNED peer gets screen capture + keystroke injection + file write + clipboard before any match. Plus HIGH/MED: CSPRNG fresh-per-attempt nonces (predictable → 0 bits), user-initiated pairing-window gating the HUD (kills pre-emption + scopes lockout so it isn't a remote DoS), modular-bias fix (derive 8 bytes then mod), frozen known-answer test, secret hygiene, clean preamble teardown before re-dial. Keep 6 digits (the bug is ordering, not length); QR full-pin path unaffected + still preferred.

**Process**: 4 parallel native adversarial lenses (Opus-orchestrated) → Opus synthesis/verification → glm-5.2 (opencode-go/pi, tool-enabled) steelman cross-check of the crux (verdict ATTACK VALID; added the both-legs-commitment refinement). The cheap reviewer + native lenses converged. Full findings + corrected construction appended to the spec's "SECURITY REVIEW OUTCOME (2026-06-19)" section. See `~/.claude/model-scorecard.md` (2026-06-19).

**Verify**: N/A (design review — no code changed). Outcome is a blocked-pending-redesign gate, not a build.

## [2026-06-19] Motion choppiness on pan/move — three coordinated cuts (keyframe, cursor lane, spring guard)

**Context**: Roadmap "Motion choppiness on pan/move" (senior/M). After the throttle + ladder work, panning/cursor-moving still felt choppy on device. Diagnosed ultracode-style: a 4-slice parallel code-map of the motion path (gesture→render, cursor-follow, viewport re-crop, input send) → ranked synthesis. Three real, mutually-reinforcing causes (the input-send lane was confirmed sound; the "low cursor report rate" suspect was refuted — the host gates on 3px, not time).

**Decision** (all build-green, unit-tested, device-verify pending):
1. **Keyframe decoupling** (the headline, was the single strongest un-mitigated stutter). `CaptureEngine.setViewport` forced an HEVC keyframe on EVERY applied re-crop; at the 150ms throttle a sustained pan = ~6.6 forced keyframes/s, each a large frame that `.bufferingNewest(2)` turns into a DROPPED frame → a periodic hitch cadenced to panning. A pure pan moves only `sourceRect` at the same encoder output size, so the P-frame stream stays valid and needs no IDR. New pure predicate `CaptureSizing.cropRequiresKeyframe(from:to:)` (= output-size changed); call site passes `requestKeyframe:` from it. Only a zoom-rung (size) change forces the keyframe now.
2. **Ordered cursor return-lane**. The host sent each `CursorPosition` via a detached `Task`-per-report (`HostRunner.makeInjector`), which could complete out of order under load → the client's cursor-follow back-stepped. New `CursorReportPump` (PortviewHostCore): single serial drain + last-wins coalescing (the cursor is absolute and the client predicts locally, so dropping intermediate samples is exact). The return-path analogue of the client's `OutboundInputPump`. Bound per connection, `finish()`ed in the serve `defer`, persists across display switches.
3. **Client spring change-guard**. `SessionViewModel`'s `.cursorPosition` case overwrote `cursorNormalized` unconditionally (unlike the `frameViewport` guard right above it), re-targeting the `Glass.cursorFollow` SwiftUI spring on every report even when it matched the local prediction → micro-stutter. Added `CGPoint.isClose(to:epsilon:)` and a guard so a confirm within ε of the prediction doesn't re-write (error bounded by ε ≈ 2.5px, self-correcting on any larger drift).

**Why #1 is safe (double-guarded against the decoder-corruption landmine)**: a real dimension change rebuilds the encoder in `pumpVideo` (`HostRunner:478-483`), which sets `needsKeyframe = true` INDEPENDENTLY of the crop request; `forceKeyframe = needsKeyframe || cropRequestedKeyframe`. So a zoom-rung IDR is guaranteed by the rebuild path regardless of #1. A pure pan = same dims = no rebuild = no keyframe (correct: panning is normal inter-frame content change, not a decode discontinuity). Zoom-1 invariant and the rapid-zoom CRASH landmine are untouched (#1 doesn't change reconfigure frequency — the ladder still gates that).

**Deferred (roadmap follow-up)**: suspect #4 — `ZoomGeometry.renderScale` is computed THROUGH `frameViewport`, so each discrete host re-crop steps the render scale and the same spring animates a small scale "pop". Low confidence, and it touches the core zoom math the zoom-1 invariant + crash-adjacent crispness depend on — so NOT fixed blind. Roadmapped with a pure ZoomGeometry invariant test (renderScale bit-stable across an f-only change) to land first.

**Process**: Opus diagnosis workflow (4 parallel mappers + ranked synthesis) → Opus TDD impl → adversarial review by **glm-5.2** (opencode-go/pi, tool-enabled — first real dispatch of this model). Verdict SHIP: it independently re-proved the #1 double-guard, the no-lost-final-value drain trace, and the bounded-ε guard, all citing real files. 1 useful nit applied (explicit `.unbounded` AsyncStream buffering — self-documents the coalescing invariant); 2 rejected (claimed `self.task = nil` is dead code — it's required for definite-init before the `[weak self]` capture, same as `OutboundInputPump`; and "test not CLI-visible" — it runs under `xcodebuild test`). See `~/.claude/model-scorecard.md` (2026-06-19).

**Verify**: `swift test` 129/37 (new `CursorReportPumpTests` + `CaptureSizing.cropRequiresKeyframe` test); iOS `xcodebuild test` 43 (new `CursorReconcileTests`); macOS BUILD SUCCEEDED. NOT pushed. **Device-verify**: high-zoom pan should be smooth (no periodic hitch) and the cursor shouldn't back-step/rubber-band while dragging. If a scale "pop" at re-crops is visible → that's deferred suspect #4.

## [2026-06-16] Magnifier: throttle viewport re-crops (track the pan, don't wait for it to stop)

**Context**: Device test — at high zoom, panning didn't repaint until the cursor STOPPED, then took ~1s to settle. The magnifier follows the host cursor, and the crop re-request went through `ViewportRequestScheduler` as an IDLE DEBOUNCE (fired 250ms after the cursor stops). So during continuous motion the host never re-cropped: you panned within the tiny 8% crop padding, ran out of captured pixels, and only saw the new region after stopping + debounce + a keyframe round-trip.

**Decision**: (1) Rewrite `ViewportRequestScheduler` as a LEADING + TRAILING THROTTLE — fire the first request immediately, then at most once per `interval` (150ms) while requests keep arriving, with a trailing fire for the resting position — so the host crop TRACKS the cursor during a pan. Safe to do now (the debounce was added 2026-06-10 to stop `updateConfiguration` stutter) because the discrete-ladder change made pan re-crops cheap: a pan is origin-only → `sourceRect`-only `updateConfiguration`, no encoder rebuild. (2) Widen `ZoomGeometry` crop padding 0.08→0.25 for more local-pan headroom between re-crops. Both knobs tunable.

**Risk to watch (device)**: re-cropping ~6×/s during a pan means ~6 keyframes/s (each applied crop forces one). If that reintroduces stutter, raise the interval or stop forcing a keyframe on pure-pan (origin-only) re-crops — deferred until the device says.

**Verify**: iOS throttle tests (leading-edge synchronous, burst→leading+latest-trailing, reset cancels trailing, near-dup suppressed) green; iOS TEST SUCCEEDED. Reviewed by qwen (tool-enabled). Device-verify: high-zoom pan repaints AS you move, not after you stop.

## [2026-06-16] Magnifier: the viewport travels in the VideoFrame (kill the echo/frame race)

**Context**: After the crash-hardening landed, qwen's adversarial review flagged a MEDIUM: the host told the client which region a frame showed via a SEPARATE `.viewport` echo (sent from the inbound-loop task) while frames were sent from the concurrent `pumpVideo` task — so at a crop change a new-region frame could arrive ~1 frame before its echo → ~16ms misalignment at zoom-rung crossings.

**Decision**: Embed the active region in EVERY `VideoFrame` — 4 normalized `UInt16` fields mirroring `Viewport`'s convention (full-display defaults so old call sites mean "whole display"). `pumpVideo` tags each frame with `capture.currentViewport()`; the client sets `frameViewport` from the frame it is rendering, so region + pixels update atomically (no cross-message ordering race). The standalone `.viewport` echo is removed from the host (the client keeps a harmless, documented fallback handler). The client assignment is change-guarded so a static region doesn't fire `objectWillChange` ~60×/s.

**Residual (honest)**: a 1–2 frame transient at crop changes still exists because SCStream doesn't tell us which delivered buffer corresponds to which `updateConfiguration` — the frame is tagged with the crop active at ENCODE time, which can lead an in-flight (`.bufferingNewest(2)`) buffer by ≤2 frames. This is inherent to SCStream and was present before (plus the now-removed ordering race). If device-test shows a visible blip at rung crossings, tag the buffer at CAPTURE time (a lock-protected rect read in the SCStream callback) — deferred.

**Process**: spec'd by Opus → implemented by a Sonnet subagent (3 gates green) → adversarial review by qwen (tool-enabled) + Opus. qwen's 2 findings (60Hz churn, dead echo case) both applied; its 4 false-positives confirmed the wire encode/decode symmetry, the clamp, the echo removal, and Equatable correct. See `~/.claude/model-scorecard.md` (2026-06-16).

**Verify**: `swift test` 126/36; iOS 38; macOS BUILD SUCCEEDED. Device-verify pending (with the ladder).

## [2026-06-16] Magnifier crash-hardening — discrete capture-size ladder (rapid-zoom de-risk)

**Context**: The 2026-06-15 region-streaming fix landed build-green but unverified, with a known crash landmine: it snapped `config.width/height` to mult-of-16 (~215 distinct sizes on a 3440px display), so a continuous pinch reconfigured the live SCStream + tore down/rebuilt the VideoToolbox encoder on nearly every step — the historical rapid-zoom crash shape. Hunted ultracode-style: a 5-model adversarial audit (haiku, sonnet, minimax-m3, qwen3.7-max, kimi-k2.7-code) → fix → tool-enabled adversarial review of the diff.

**Decision**: Snap the **captured region's size** to a coarse geometric ladder (`CaptureSizing.snapCropFraction`, ratio 0.8 ⇒ ~13 rungs across the zoom range), snapped UP so the captured region still ⊇ the requested window. `setViewport` captures that snapped region (recentered on the request, clamped) and the encoder output is sized from the SAME snapped fractions, so the buffer aspect equals the captured-region aspect exactly (no stretch). The host now ECHOES the snapped region (not the raw request); the client sets `frameViewport` from it so its zoom transform stays aligned. SCStream/encoder reconfigure only at rung crossings (~13 vs ~215) → the rebuild churn that caused the crash is gone, at the cost of crispness stepping in discrete rungs (≤~20% below native; densify the ladder if device-test shows softness).

**Why snap the captured region, not just the output buffer**: the Metal client aspect-fits the *buffer* dims while `ZoomGeometry` computes its transform from the *crop* aspect (`frameViewport`) — so the buffer aspect MUST equal the captured-region aspect or the magnified image misplaces/stretches. Snapping only the output (independent per-axis) would break that; snapping the captured region keeps sourceRect, output buffer, and echo all derived from one snapped fraction.

**Also fixed** (audit findings, verified real): config save/restore on `updateConfiguration` failure (it was mutated before the throwable call → desynced the unchanged-check baseline → could wedge the crop); `encoder = nil` on encode failure (was re-entering a wedged VT session every frame); stale `ZoomGeometry` doc-comment. **Verified-not-bugs** (audit false positives): the "config reference-type *race*" (each connection owns its `CaptureEngine`; the inbound loop *awaits* `setViewport` → no concurrent writer; qwen refuted the related encoder use-after-free) and `.zero` sourceRect (Apple's documented full-display sentinel).

**Adversarial review** (sonnet, tool-enabled, 19 tool uses): PROVED the snap+clamp safety invariant (captured region always ⊇ requested window), idempotency, echo-doesn't-misplace, inbound-loop atomicity; one real LOW (near-full snap seam) fixed by deciding `cropping` off the snapped fractions. Deferred (physically unreachable at ≤~6× max zoom): anisotropic floor stretch when both axes hit the 64px floor.

**Model head-to-head note**: the cheap pi models (qwen3.7-max, minimax-m3) out-accurated the native subagents here — both natives led with the unreachable config-race "critical"; qwen explicitly refuted it. See `~/.claude/model-scorecard.md` (2026-06-16 entries).

**Verify**: package `swift test` 125/36; iOS 38; macOS BUILD SUCCEEDED. **DEVICE-VERIFY still required** — confirm rapid zoom in/out no longer crashes (the whole point), text stays crisp, and zoom feels continuous despite discrete rungs. Spec addendum: `docs/superpowers/specs/2026-06-15-magnifier-region-streaming.md`.

## [2026-06-16] M7 — Host presence & frictionless connect (menu-bar, live permissions, input order)

**Context**: Device testing surfaced pairing/permission friction + choppy input. M7 makes the host pleasant to live with. Driven ultracode-style across phases: a design workflow (4 grounded specs) → implement P1–P3 → an adversarial-review workflow (5 findings, all fixed) → commit.

**P1 Menu-bar host**: a `MenuBarExtra(.window)` scene beside the `WindowGroup` (now `id "main"`), sharing the single `@State HostAppModel`; `MenuBarHostView` = compact status + real QR + copy-URL + connected count + Start/Stop + "Open window" (`@Environment(\.openWindow)`). Dynamic glyph via a pure, tested `HostMenuBar.symbol(...)`. Hosting now **outlives window-close** (removed the `WindowGroup`'s `onDisappear { stop }`) so the menu bar keeps advertising.

**P2 Live permissions onboarding**: `HostAppModel` publishes REAL `screenRecordingGranted` (`CGPreflightScreenCaptureAccess`, no prompt) + `accessibilityGranted` (`AXIsProcessTrusted`), polled every 2s for the **app lifetime** (not window-scoped). Pure tested `PermissionsOnboarding` derives the guided step/title/body/pane + the Screen-Recording-needs-relaunch caveat; `ContentView` shows real badges + a guided banner (Open Settings + Re-check), replacing the old inferred `PermissionStatus`.

**P3 Input serialization**: `OutboundInputPump` — one ordered FIFO lane per connection (queue + wake-signal drain) that **coalesces consecutive pointer-moves** (summed deltas, latest-wins) while keeping discrete events ordered + lossless; bound/unbound at every connection set/clear (run/reconnect/disconnect). Fixes both the down/up ordering and the move-lurch-under-stall (relevant to the reported choppiness).

**P4 SAS 6-digit pairing**: DESIGN ONLY — a cryptographically-sound cert-comparison (SAS) scheme in `docs/superpowers/specs/2026-06-15-sas-pairing-design.md`, **flagged for human security review** before implementation (client-side-only match check, modular bias, unpinned preamble — all enumerated).

**Adversarial review (3-dim, 5/5 confirmed, all fixed)**: (medium) uncoalesced pointer-moves on an unbounded lane → folded into P3's coalescing; (medium) `isRunning` was derived from the `@ObservationIgnored` task, so the menu glyph + Start/Stop went stale when the serve loop ended while ready → made it an **observed stored bool** set in start/stop/self-clear; (3× low, one root) permission monitoring was window-scoped while hosting outlives the window → moved to **app-lifetime** (idempotent start, no window-close stop), fixing the window-close-stop, menu-bar staleness, and multi-window race.

**Verify**: package `swift test` **122/36**; iOS `xcodebuild test` **38**; macOS **BUILD SUCCEEDED**. Device-verify pending: menu-bar QR/connect; live permission flow (grant Accessibility → dot flips ≤2s; Screen Recording → relaunch); smoother drag.

## [2026-06-15] Magnifier = true region streaming (output dims match the crop aspect)

**Context**: High zoom (~5×, needed to read text on a phone) was blurry/distorted vs VNC. Root cause (3440×1440 ultrawide host + portrait iPhone): the host never cropped. `ZoomGeometry.cropRequest` built a normalized SQUARE (`max(visW, visH)`), which for a full-height window = the whole display; and `CaptureEngine.setViewport` only moved `sourceRect` while keeping output dims = full display, so any non-display-aspect crop would STRETCH (hence the square requirement). Net: the client digitally zoomed a full, low-bitrate frame.
**Decision**: Stream the actual region. (1) Client `cropRequest` = the visible window's OWN aspect (not square), padded for pan. (2) Host sets BOTH `sourceRect` AND `config.width/height` to the crop's pixel size (`CaptureSizing.cropOutputSize`: mod-16/even, capped to display-native, min floor) → the region is encoded 1:1, no stretch, full res. (3) Client render computes its aspect-fit from the FRAME's aspect (`frameAspect = (f.width/f.height)·displayAspect`), not the display's.
**Invariant (no regression)**: at zoom 1 the crop is the full display (display-aspect) → `frameAspect == displayAspect` → the math is identical to the prior overview. Only zoom > 1 (the broken path) changes.
**Churn / crash control** — landmine: the 2026-06-04 tight-crop/native-res attempt CRASHED + stretched. Output dims change only when the crop SIZE changes (i.e. zoom), not on pan (panning moves `sourceRect` only → no encoder rebuild); dims are quantized (mod-16) + capped + floored so jitter near a zoom level doesn't thrash `updateConfiguration`/the encoder; the 250 ms viewport debounce + "near-full = no crop" short-circuit stay.
**Tests**: `ZoomGeometryTests` (zoom-1 unchanged + scale 1; high-zoom on ultrawide crops a real region that follows the cursor; settled render finite/zoomed) + `CaptureSizing.cropOutputSize` (even/cap/floor). Build-green: 113 pkg / 36 iOS / macOS builds. **DEVICE-VERIFY REQUIRED** — changing `config.width/height` + `updateConfiguration` on a live SCStream is the historical crash point. Spec: `docs/superpowers/specs/2026-06-15-magnifier-region-streaming.md`.

## [2026-06-15] Three device-testable features: quality controls, endpoint-based persistence, Mac→iPhone files

**Context**: User asked to "burn through real features" they can test on-device. Picked three high-observability ones (ultracode; build-green, device-verify pending).

**1. Quality controls — the host now HONORS the client's requested bitrate/fps.** Found that `serveSession` hardcoded `capture.start(maxFPS: 60)` and the encoder used a width·height heuristic, so the client's `StartSession.targetBitrate`/`maxFPS` were *ignored*. Now `serveSession` captures them (clamped via the new `StreamParameters`: fps 10–60, bitrate 2–120 Mbps; 0 = "unset" → fps 60 / heuristic) and threads them into `pumpVideo` (`capture.start(maxFPS:)` + `VideoEncoder(averageBitRate:)`), reused across display switches. Client: `ClientSettings` (persisted bitrate 4–80 Mbps + fps 30/60) read at handshake time via `ClientSettings.load()` instead of the old hardcoded 25 Mbps/60; a Glass **Settings** sheet (gear on Deck Home) edits them + "Forget all saved Macs" + version. This is the real knob for the long-running crispness investigation (raise bitrate → HUD shows it → crisper). Decided client-reads-UserDefaults-at-handshake over injecting a settings object (decoupled; applies next connect).

**2. Resolved-endpoint persistence — unified, replacing `PairingCoordinator`.** `PortviewConnection.resolvedRemoteEndpoint` (`currentPath?.remoteEndpoint`) exposes the live concrete `host:port`. On first stream, `SessionViewModel` publishes `connectedHostToSave` (name + resolved IP + pin) for ALL paths; `ContentView` persists it. This fixes the two deferred items at once: discovered (Bonjour `.service`) pairings now persist with a concrete IP (review #2 from the Glass batch), and a moved saved Mac's IP refreshes in place. `SavedHostsStore.upserting` matches **name → host:port → pinHex** (the pinned cert is the stable per-Mac identity, so a manual-IP entry and a later Bonjour entry for the same Mac fold into one rather than duplicating). Retired `PairingCoordinator` (+ its test) — the resolved-endpoint signal supersedes the markPending/commit dance.

**3. Mac→iPhone file transfer (completes M5 both directions).** Host "Send a file" card → `NSOpenPanel` → `HostControl.sendFile(…, to: sessionID)` streams `FileOffer`+64 KB `FileChunk`s over the active connection. Client `IncomingFileTransfers` **streams each chunk straight to disk** (a per-transfer UUID temp dir), never buffering the whole file (bounded iPhone memory), then publishes a `ReceivedFile` the UI offers via `ShareLink`.

**Security + adversarial review.** Automated security pass flagged **path traversal** — the host-supplied filename was joined into a temp path; now sanitized to a safe last-path-component at offer time (`..`/`.`/empty rejected), TDD'd. A 3-dimension review found 6 (all confirmed, all fixed): the in-memory-buffering OOM risk (→ stream to disk, MEDIUM), partial-transfer state not reset across reconnect (→ reset at each `streamSession` start), nondeterministic multi-client send target (→ target by `sessionID`), manual-vs-Bonjour duplicate (→ pin tiebreaker), temp-file aliasing (→ per-transfer dir), and disconnect dropping an in-hand received file (→ clear `receivedFile` on `start()` not `disconnect()`, so it survives a disconnect for sharing).

**Verify**: package `swift test` 110/34; iOS `xcodebuild test` 31/31; macOS BUILD SUCCEEDED. Device-verify pending (see roadmap Now): the quality knob's visible effect, discovered-Mac persistence across relaunch, IP refresh after a move, and a round-trip file send.

## [2026-06-15] Glass HUD visual direction across both apps (design handoff)

**Context**: A claude.ai/design handoff (`design_handoff_portview_glass_hud`, fetched as a gzip bundle from the share URL) locked the "Glass HUD" look — 6 iOS screens + 3 macOS host states — to recreate in the existing SwiftUI, wired to real types (no parallel state). User chose "build everything" (incl. the two states needing new model surface) + System fonts.
**Decision**: Per-app `GlassTheme.swift` (the two apps are separate XcodeGen targets; the SwiftPM core has no SwiftUI, so the token language is duplicated, not shared). Glass = `Material`/`.ultraThinMaterial` + dark tint + border/inset (README asked for Material, NOT iOS-26 Liquid Glass `glassEffect`). **Fonts: System SF (grotesque) + SF Mono (all numeric telemetry)** — the README explicitly blesses already-licensed equivalents; chosen over bundling Schibsted Grotesk/JetBrains Mono to avoid committing font binaries. Kept the real critically-damped cursor-follow spring (response 0.1 / damping 1.0). Real QR on the host via CoreImage `CIQRCodeGenerator` + `falseColor` tint (signal-on-dark).
**No fabricated data** (the hard rule): the quality panel/rail surface **real** `QualityDiagnostics` — link Mbps, fps, decode ms, encode ms. The mock's hero "LATENCY 42 ms" is **omitted**, not faked — RTT is measured nowhere in the app (a pong-timestamp metric is a possible follow-up). The host activity log filters CLI-only multi-line artifacts (ASCII box + terminal QR) rather than inventing timestamps. Host "Sharing Display" card is static (display switch is client-driven; the host model has no picker).
**Two states needed new (real) model surface, built rather than faked**:
- **iOS `.reconnecting`** — new `SessionViewModel.Status` case + bounded mid-session re-bind: on a mid-stream drop (not a user `disconnect()`), spin a `PortviewBrowser`, rebuild candidates (Bonjour-by-name first, then the endpoint that worked — `reconnectCandidates`, unit-tested), retry the pinned handshake within a 30 s window. `rediscover` uses a `withTaskGroup` browse+timeout race with `browser.stop()` to terminate the browse task (no deadlock). Orchestration is build-green / device-verify-pending (repo house style — run-loop mock tests stay YAGNI; the pure candidate logic is unit-tested).
- **macOS "device connected" (state C)** — `HostRunner.serveSession` now `emit`s `.deviceConnected(name from ClientHello)` / `.deviceDisconnected` / `.sessionStats` (throughput/fps/encode from the existing `QualityStatsAccumulator` + display dims). A pure `HostSessions` reducer (unit-tested) folds these; `HostAppModel` exposes the derived state + `connectedSince`. A `HostControl` (NSLock registry) backs a **real Disconnect that keeps the listener advertising** (no port churn).
**Adversarial review (4-dimension workflow, 9/9 confirmed real)** — fixed: (1, high) host Disconnect sent a bare close that the client's new auto-reconnect undid → host now sends `.bye` first; client treats `.bye` as a deliberate terminal close (`.evicted`), only a bare drop re-binds; (3) `sendClick()` down+up now share one Task so they can't invert into a stuck click; (6) live toolbar reordered to gauge→keyboard→paste→file per spec; (7/8) host "connected mm:ss" now ticks via `TimelineView` (was reading `Date()` with no clock); (9) per-connection **UUID** session identity so a stale disconnect during reconnect can't evict the live session. Deferred: (2) persisting a *discovery-paired* Mac needs the resolved remote endpoint — same blocker as the existing "refresh saved fallback IP" follow-up; not a regression (matches prior behavior). No-action: (4) LINK promoted to the signal hero after LATENCY's removal (reviewer: the better choice); (5) static Sharing-Display card (honest — no host picker).
**Verify**: package `swift test` 104/33; iOS `xcodebuild test` 17/17; macOS `xcodebuild` BUILD SUCCEEDED; CLI builds. Device-verify pending: live reconnect on a real IP change, host state C with a real connected device, the Glass look on-device.

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

## [2026-06-14] Saved-Mac reconnect survives LAN IP changes via Bonjour name-rediscovery

**Context**: With stable pin+port (2026-06-13), a saved Mac still failed to reconnect after its LAN IP changed (DHCP) — the client only tried the stale saved `host:port`. Client-only follow-up.
**Decision**: At saved-Mac reconnect, build ordered connection candidates — a live Bonjour host **matching by name** first (its `.service` `NWEndpoint` re-resolves to the current address), then the saved `host:port`. `SessionViewModel.run` tries candidates until the **pinned** QUIC handshake succeeds (initial connect only — a mid-stream drop never re-targets). The saved **pin is unchanged**, so cert pinning gates every candidate; the Bonjour name is only a routing hint (a same-name impostor can't present the pinned cert). Discovery already runs on the connect screen, and `DiscoveredHost.name == SavedHost.name` (both the Mac's Bonjour name), so the join is by name.
**Alternatives**: saved-IP-first then Bonjour-on-failure (eats a connect-timeout on the exact case we're fixing); re-resolve + rewrite the saved IP (needs the resolved address off the connection — deferred, see below).
**Rationale**: Off-LAN uses the saved IP (Tailscale IPs are stable per device); on-LAN, name-rediscovery makes reconnect robust to IP churn. Strictly better than before (reconnect used to just fail).
**Deliberately deferred (review-flagged)**: after a Bonjour reconnect to a new IP, the saved entry keeps the OLD IP (re-saved as-is by `PairingCoordinator`). Not a regression — on-LAN rediscovery works every time by name regardless; the stale IP is only the off-LAN fallback. Refreshing it needs `PortviewConnection` to expose the resolved remote endpoint (a transport API change, out of this client-only scope). Tracked as a roadmap follow-up.
**Adversarial review**: 3-dimension / 8-confirmed pass. Rejected: the "cancellation regression" (cancellers own status; new loop reduces a pre-existing disconnect race) and run-loop mock-tests (would need a connection-injection seam for trivial loop mechanics; ordering is unit-tested). Accepted: manual-IP-name fallback + duplicate-name single-endpoint tests.

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

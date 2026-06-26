# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Latest Session (2026-06-26 — zoom: capture-time frame tagging (last re-crop glitch))

- Device-confirmed the smooth-pan fix: "so much better at bigger zooms… a lot smoother… mouse really smooth." ✅ Last artifact: picture **flashes wrong content when repainting at the screen edge**. User characterized it as a jump/flash (not a smear) → the deferred **#5 capture-vs-encode tag skew**.
- **Fix (host-side only; build-green; device-verify pending — needs the rebuilt host relaunched)**: tag each frame with the crop region captured WITH the buffer, not the live viewport at encode time. `SendableFrame.region` snapshotted in the SCStream callback (`appliedRegion`, lock-guarded, set when `updateConfiguration` takes effect); `pumpVideo` tags from `frame.region`. So an old-crop buffer encoded after a re-crop carries the OLD region → client maps the window into the region the pixels actually show → no flash. Doesn't touch the capture-size ladder (no crash risk). Commit cd6c8d9. Decision: decisions.md (2026-06-26 top).
- Verify: `swift test` **158**, macOS BUILD SUCCEEDED. Client unchanged (already maps into the frame's region) — Roshar already has the latest client; only the HOST needs relaunching.
- **Host now installed at `/Applications/PortviewHost.app`** (ditto'd from the build) — stable path so TCC grants persist across updates; STOP building host to /tmp for device tests (forces re-grant). See memory `host-app-install-location`. Future host updates: `ditto <build>.app /Applications/PortviewHost.app` (quit first if running).
- Zoom render saga now: A present-sync (tear) → C in-shader (jumps) → display-link ease (smooth pan ✅) → capture-time tagging (re-crop flash). All but the last device-confirmed.
- NEXT (device verify): relaunch the new host, pan to the edge zoomed → no wrong-content flash. Then the host-side queue (SAS, motion, M7) is finally testable on the same relaunched host.

## Latest Session (2026-06-24 — zoom smooth-pan: display-link eased render loop)

- Device test of Phase C: tearing gone but pan **"even jerkier."** systematic-debugging + 2 user diagnostic answers localized it: **jerky only when panning, smooth when still + at zoom 1** → cursor-follow pan, not the stream. Root cause: Phase C dropped display-rate smoothing (window stepped at video-frame rate, no interpolation) — strictly less than Phase A's CA spring.
- **Fix (build-green; device-verify pending — Roshar went unavailable mid-install)**: keep in-shader zoom, but drive rendering from a **CADisplayLink** and **ease the window toward the cursor at display rate**. `ZoomGeometry`→`visibleWindow` (display coords; dropped the `frameViewport` param). Renderer: `targetWindow`/`currentWindow`/`lastPixelBuffer`/`latestFrameRegion`; `submit(buffer,region)` stores a frame; `tick()` eases + maps window→UV per vsync + draws. `SessionViewModel` pushes `targetWindow` on cursor/zoom; `submit`s frames. `MetalVideoUIView` owns the link. Time-normalized easing (60/120Hz parity); snap on display switch.
- Reviewed native SHIP-WITH-FIXES (no frame-drop, no race, zoom-1 + no-jump invariants hold) → applied 2: refresh-rate-independent easing (Roshar=120Hz ProMotion), snap-on-display-switch. Deferred: pause display link at idle (minor power).
- Tests: `MetalVideoRendererTests` (no-jump invariant moved here + easing-settles + window-past-frame) + `ZoomGeometryTests` updated. Verify: iOS `xcodebuild test` **47**.
- NEXT (device verify when Roshar's back — build ready at /tmp/pv-client): zoomed pan should be SMOOTH (headline), tearing still gone, crisp; tune `MetalVideoRenderer.easingFactor` (0.28) if it feels laggy(lower) or steppy. This is the 3rd render iteration (A present-sync → C in-shader → display-link ease); device-confirm before declaring done.

## Latest Session (2026-06-22 #2 — zoom Phase C: in-shader zoom (tearing + jumps fixed))

- Device-verified Phase A: **tearing GONE**, but the picture **still jumped/repainted** when panning → implemented **Phase C** (in-shader zoom). Build-green; installed on Roshar; device-verify pending. Decision: decisions.md (2026-06-22 top, updated). Roadmap item `[~]` (A+C both done, device-verify C).
- **Phase C**: `ZoomGeometry` now emits `sampleRect` (visible window mapped into the current frame's region, texture UV) instead of `renderScale`/`pan`; the Metal fragment shader samples that sub-rect into the full-res drawable (`uvRect` uniform); `LiveHUDView` dropped `.scaleEffect/.offset/.animation`. **`sampleRect` is computed PER-FRAME in `SessionViewModel` against that frame's own region** (view pushes only `magnifierZoom`+`magnifierViewSize`) → UV and pixels are the same generation (no 1-frame re-crop jump). Not clamped to [0,1] → a fast pan-past edge-clamps (sampler) instead of pinching. On-screen window invariant to re-crops; full-res sampling (crispness bonus). zoom-1 reduces to the prior letterboxed overview.
- **Review (native, SHIP-WITH-FIXES) caught 2 real bugs I fixed before commit**: (#1 HIGH) sampleRect pushed via SwiftUI onChange lagged render() by a frame → 1-frame jump on every re-crop → moved the computation into the per-frame render path; (#2 MED) clamping pinched the picture on a fast pan-past → unclamp + let the sampler edge-clamp.
- New pure test `testSampledWindowIsInvariantToFrameViewport` locks the no-jump invariant (display-window recovered from (sampleRect,f) constant across f). Verify: iOS `xcodebuild test` **44**.
- NEXT (device verify): zoomed pan should be **smooth (no jumps) + crisp**, tearing still gone. If good → close the zoom item. Standing queue: SAS core+E+C-cap, motion fix, M7 (need the relaunched host).

## Latest Session (2026-06-22 — first device test of the magnifier; zoom-tearing Phase A + menu-bar Quit)

- **FIRST ON-DEVICE MAGNIFIER TEST** (user, Roshar): **NO CRASH** — the rapid-zoom landmine is cleared on hardware ✅ (the whole point of the discrete capture-size ladder). Crispness "usable for now", Glass look great, persistence good. Two issues reported: (a) **screen tearing + repaint glitches when zoomed**; (b) menu-bar couldn't kill the host.
- **(b) FIXED**: menu-bar **Quit Portview Host** (`NSApp.terminate`), `21a791e`. "Stop" still only stops hosting.
- **(a) diagnosed via ultracode workflow** (3 code lenses + web-research → synthesis). Root causes: async CAMetalLayer present under a SwiftUI `.scaleEffect` CA transform (tear); `renderScale` steps per host re-crop (repaint jumps, the deferred #4); CA-upscale of a 1× drawable (softness). **Correction I verified by deriving the math**: the synthesis's "Phase B" (f-invariant renderScale as a CA-only change) is NOT achievable — it needs C's shader windowing. Real split: **A kills tearing; C kills repaint-jumps + crispness; no cheap middle.**
- **Phase A DONE** (build-green; device-verify pending): `MetalVideoRenderer` — `presentsWithTransaction = true` + `maximumDrawableCount = 3`; `render()` → `commit(); waitUntilScheduled(); drawable.present()` (manual present on the @MainActor path, enrolls in the zoom transform's CATransaction). Client-render-only; can't touch the host crash ladder. Decision: decisions.md (2026-06-22 top). Verify: iOS 43, BUILD SUCCEEDED.
- **Phase C QUEUED** (roadmap Now `[~]`): move zoom+pan into the Metal shader (UV sub-rect uniform; drop `.scaleEffect/.offset/.animation`), on-screen scale invariant to re-crops, full-res sampling. L visual rewrite — deliberately NOT blind-shipped (needs device iteration; Roshar currently down). TDD ZoomGeometry's UV-rect output + preserve the zoom-1 invariant when done.
- NEXT: device-verify Phase A (zoomed pan should no longer tear). If repaint-jumps remain → implement Phase C. Plus the standing device-verify queue (SAS core + E + C-cap, motion fix, M7).

## Latest Session (2026-06-21 #2 — host-side SAS preamble integration test)

- Closed the last SAS test-coverage gap: `SASPreambleIntegrationTests` drives a real client commit→reveal→confirm over a loopback QUIC connection against the real `serveSASPreamble` (visibility `private`→`internal` so the test can call it; mirrors the production peek→dispatch, tolerates QUIC double-delivery). 3 cases: happy path (`.sasCode(matching)` + `.sasConfirmed`, captured cert == host cert), forged confirm (code but NO `.sasConfirmed`), closed window (nothing served). Build-green; not pushed. Roadmap follow-up (a) `[x]`.
- Verify: `swift test` **158** (+3). Only remaining SAS follow-up: per-source preamble rate-limit (deferred, gated on fuzzy QUIC endpoint).
- NEXT: human device-verify queue (SAS core + E, motion fix, M7, magnifier crash landmine) — all build-green awaiting Roshar.

## Latest Session (2026-06-21 — SAS Guardrail C: bound the connection accept loop)

- Hardened `HostRunner.serveConnections` from an UNBOUNDED `withTaskGroup` to a capped one (`maxConcurrentConnections = 16`, backpressure via `await group.next()` before adding). Bounds a connection flood / many ~25s-lingering SAS preamble tasks (the surface E made more pressing). Build-green; not pushed. Decision: decisions.md (2026-06-21 top). Roadmap SAS follow-up (b) `[x]`.
- Reviewed SHIP (native): cap accounting correct (no off-by-one), liveness preserved (no drops), no deadlock/starvation, clean cancellation; tests aren't flaky.
- Tests: `ServeConnectionsTests` (peak ≤ cap + all-served; strict-serial at cap 1). Verify: `swift test` **155**, macOS host BUILD SUCCEEDED.
- Deferred (roadmap, non-blocking): host-side `serveSASPreamble` integration test; per-source preamble rate-limit.
- NEXT: the standing human device-verify queue (SAS core + Guardrail E, motion fix, M7, magnifier crash landmine) — all build-green awaiting Roshar.

## Latest Session (2026-06-20 #2 — SAS Guardrail E (HMAC host-confirm) IMPLEMENTED, ultracode arc)

- Built SAS Guardrail E (phase-2 defense-in-depth: authenticated host "✓ a client confirmed" signal). Build-green, device-verify pending. NOT pushed. Decision: decisions.md (2026-06-20 top). Roadmap SAS item sub-checkbox `[x]`. Spec: the "E (detailed design)" + "E — design-review RESOLUTIONS" sections of `docs/superpowers/specs/2026-06-19-sas-pairing-v2-commit-reveal.md`.
- **Full ultracode arc**: Opus designed E → 4-lens design-review **workflow** (crypto/MITM/lockout-DoS/impl-fit) → verdict **SOUND-WITH-FIXES, weakensV2=false**, 6 must-fixes (all caught pre-implementation from the real code) → folded into the spec → TDD implement → dual impl review (native + glm-5.2, both **SHIP-WITH-FIXES**), 2 LOW test-fixes applied.
- **The build**: `SASClientConfirm` msg (tag 24); `SASCode.confirmation` = HMAC over an HKDF-derived, domain-separated key + constant-time `verifyConfirmation` + frozen KAT (`4338ee3c…`); host `serveSASPreamble` reads EXACTLY ONE bounded confirm (25s timeout Task closes the conn so `inbound.next()` can't hang) → `.sasConfirmed` (positive signal only, NEVER closes the shared window — kills the relayed-confirm DoS); attempt counting stays at engagement start; client HOLDS the preamble connection through typing, sends the confirm on match via a detached task, with ONE `teardownSAS` chokepoint closing+zeroing on all 5 exits.
- **Doesn't weaken v2** (both reviews verified vs real code): purely additive — confirm-less client still pairs via the pinned re-dial; host never gates the session on a confirm; CRITICAL-3 preamble fence intact; a forged confirm is inert + can't suppress the cap.
- Deferred → roadmap: host-side `serveSASPreamble` integration test; Guardrail C concurrent-preamble cap (pre-existing unbounded `serveConnections`).
- **glm-5.2**: 5-for-5 5/5 on tool-enabled review this session (now incl. the E design-review workflow lens contributions + the E impl cross-check). Scorecard updated (2026-06-20 #2).
- Verify: `swift test` **153**, iOS `xcodebuild test` **43**, macOS BUILD SUCCEEDED.
- NEXT (human device verify): pair via the 6-digit code → the Mac briefly shows "✓ a client confirmed" as the phone connects. Plus the standing device-verify queue (SAS core, motion fix, M7, magnifier crash landmine).

## Latest Session (2026-06-20 — SAS pairing v2 IMPLEMENTED, build-green, device-verify pending)

- Implemented the design-cleared SAS v2 commit-then-reveal pairing end-to-end, TDD, layer by layer. Reviewed SOUND (native SHIP + glm-5.2 IMPL SOUND). NOT pushed. Decision: decisions.md (2026-06-20 top). Roadmap item now `[x]`. Spec: `docs/superpowers/specs/2026-06-19-sas-pairing-v2-commit-reveal.md`.
- **Layers**: (1) `PortviewProtocol` — `SASCode` (commit/derive HKDF L=8/randomNonce) + 4 messages tags 20–23 + `MessageType`/`AnyMessage`/`Frame` wiring + **frozen KAT `470719`**. (2) `PortviewTransport` — `SASPreamblePinning` (SEPARATE TOFU type) + `clientCapturingCert` + `connectCapturingCert` + the missing **negative-pin test**. (3) `PortviewHostCore` — `serveSession` first-message role-lock → `serveSASPreamble` (NO clipboard/injector/capture/file; loop refactored to single-iterator while-let) + `SASAttemptLimiter`/`SASPairingControl` (window + window-scoped cap) + `HostRunnerEvent.sasCode` (never logged). (4) host app — pairing window + displayed code, cleared on connect/timeout/stop. (5) client — `beginSASPairing`/`submitSASCode` + `SASPairingSheet` (replaces 64-hex alert) + pinned re-dial with the captured hash.
- **Security crux preserved** (both reviews verified against real code): host commits its nonce before the client reveals; client commits before the host commits; every reveal verified against its commit (right role+cert) before use → MITM must commit both substituted nonces blind → offline grind dead. TOFU type-isolated from the pinned path; preamble can't reach the streaming surface (no fall-through). 2 LOW polish fixes applied (stale-code-after-window guard; cancel-mid-handshake guard).
- **glm-5.2**: 4-for-4 5/5 on tool-enabled review this session (design steelman ×2 + impl review). Scorecard updated (2026-06-20).
- Verify: `swift test` **148**, iOS `xcodebuild test` **43**, macOS BUILD SUCCEEDED.
- NEXT (human device verify): Mac menu-bar → "Pair with a 6-digit code" → iPhone taps discovered Mac → SAS sheet → type the shown code → connects (pinned); a wrong code refuses. Plus the still-pending device-verify queue (motion fix, M7, magnifier crash landmine). Optional next code phase: HMAC host-confirm (Guardrail E, phase-2).

## Previous Session (2026-06-19 #3 — SAS pairing v2: commit/reveal redesign, cleared SOUND)

- **Authored the SAS v2 redesign** after #2's review returned v1: `docs/superpowers/specs/2026-06-19-sas-pairing-v2-commit-reveal.md` (supersedes v1's construction). Design only — NOT implemented. Decision: decisions.md (2026-06-19, top ADR). Roadmap item now "DESIGN CLEARED, READY TO IMPLEMENT".
- **The fix**: two-sided ZRTP-style **commit-then-reveal**. Both sides send `commit = SHA256("Portview SAS commit v2"‖role‖H_cert‖nonce)` BEFORE either reveals its 16B CSPRNG nonce; reveals gated on both commits + verified. Forces an active MITM to commit BOTH substituted nonces **blind on both legs** → offline grind dead, residual = intended ~1/10⁶ per human-attended attempt. **Keystone**: binding the cert hash INTO the commit (not just the HKDF salt) makes a forwarded commit fail the other leg's check → forces the MITM to mint its own commit, which the per-leg gate blinds.
- Also folds in: `SASPreamblePinning` as a SEPARATE type (+negative pin test), dedicated `serveSASPreamble` (no clipboard/injector/capture/file; first-message role-lock), user-initiated pairing window + **mandatory window-scoped attempt cap**, modular-bias fix (HKDF L=8), frozen KAT, secret hygiene, clean pinned re-dial. 6 digits kept. HMAC host-confirm optional phase-2.
- **Adversarially verified SOUND** by two independent reviewers: a native deep reviewer + a glm-5.2 tool-enabled steelman. Both re-ran the MITM timeline under pipelining (blind-on-both-legs holds), verified commitment hiding/binding/no-reflection, found NO new flaws, and tested a decoupling/flicker variant (stays 1/10⁶, human typing is the limiter). Convergent upgrade applied: attempt cap → MANDATORY. glm-5.2 now 3-for-3 5/5 on tool-enabled review (scorecard 2026-06-19).
- NEXT: if the user wants, **IMPLEMENT SAS v2** (lead-tier; new messages 20–23, SASCode+KAT, SASPreamblePinning, serveSASPreamble, client SAS sheet, host pairing window — full TDD plan in the spec). Otherwise the human-gated device-verify queue remains (motion fix, M7, magnifier crash landmine).

## Previous Session (2026-06-19 #2 — SAS pairing security review: design returned, broken vs active MITM)

- **Security review of the 6-digit SAS pairing design** (was "awaiting human security review"). Outcome: ❌ **DO NOT IMPLEMENT as specified** — returned to author for redesign. No code changed (design review). Decision: decisions.md (2026-06-19 top); full findings + corrected construction in the spec's new "SECURITY REVIEW OUTCOME (2026-06-19)" section; roadmap Next item updated.
- **CRITICAL crux (the scheme doesn't bind)**: SAS code = public `f(certHash, n_c‖n_h)`, revealed **client-nonce-first with NO commitment**. Active MITM (cert_M to client, cert_H captured) knows the host's displayed code before sending its last nonce to the client → **grinds ~2²⁰ nonces offline in ~ms** to force the codes equal (limiter never fires — no honest party involved); user transcribes the match; pin re-dial then pins the client TO THE ATTACKER. Spec open-Q#3 ("cert salt dominates") resolves ADVERSELY (active attacker knows both hashes).
- **Required fix**: two-sided **ZRTP-style commit-then-reveal** (new `sasClientCommit`/`sasHostCommit`; both legs — one-sided lets the MITM pipeline). Then 6 digits = intended 1/1e6 (the bug is ordering, not length; more digits/lockout-alone don't fix it).
- **+2 CRITICAL impl traps** the test suite wouldn't catch: (a) TOFU `installCapturing` must be type-level-isolated from the pinned path (separate type, not a `Bool` flag; + negative pin test); (b) a separate `serveSASPreamble` — `serveSession` builds clipboard/injector/capture/file scaffolding BEFORE its switch, so an unpinned peer would get the full live surface pre-match. Plus HIGH/MED: CSPRNG fresh nonces, user-initiated pairing window (scopes lockout, kills pre-emption), modular-bias fix, frozen known-answer test, secret hygiene, clean re-dial.
- **Process**: 4 parallel native adversarial lenses (crypto/MITM/replay-DoS/impl-vs-code) → Opus synthesis → glm-5.2 tool-enabled steelman of the crux (tried to refute, confirmed ATTACK VALID, added the both-legs refinement). glm-5.2 now 2-for-2 5/5 on tool-enabled review (scorecard 2026-06-19). QR full-pin path unaffected + still preferred.
- NEXT: if the user wants, do the SAS commit/reveal REDESIGN (lead-tier) — author the revised spec, re-review, then implement. Otherwise the still-pending device-verifies (motion fix below, M7, magnifier crash landmine) remain the human-gated queue.

## Previous Session (2026-06-19 — motion choppiness on pan/move: three coordinated cuts)

- Roadmap "Motion choppiness on pan/move" (senior/M) DONE, build-green, **device-verify pending**. Ultracode: Opus 4-slice motion-path diagnosis workflow (gesture→render / cursor-follow / viewport re-crop / input send) → ranked synthesis → TDD impl → glm-5.2 tool-enabled adversarial review (SHIP). Decision: decisions.md (2026-06-19 top).
- **#1 keyframe decoupling (headline)**: `CaptureEngine.setViewport` forced an HEVC keyframe on EVERY re-crop → ~6.6/s during a pan → `.bufferingNewest(2)` drops the frame behind each → periodic hitch. New pure `CaptureSizing.cropRequiresKeyframe(from:to:)` → keyframe only on an output-SIZE change (zoom rung), not a pure pan. Double-guarded: a real dim change rebuilds the encoder (`HostRunner:478-483`) which sets `needsKeyframe` independently, so no path drops a needed IDR. Zoom-1 + crash landmine untouched.
- **#2 ordered cursor return-lane**: `CursorReportPump` (PortviewHostCore) — single serial drain + last-wins coalescing — replaces the detached `Task`-per-report (`HostRunner.makeInjector`) that could reorder under load and back-step the client cursor. Per-connection, `finish()`ed in serve `defer`, persists across display switch. Return-path analogue of `OutboundInputPump`.
- **#3 client spring guard**: `.cursorPosition` overwrote `cursorNormalized` unconditionally (unlike the `frameViewport` guard above it) → re-targeted the `Glass.cursorFollow` spring per report. Added `CGPoint.isClose`; skip a confirm within ε of the local prediction (error bounded ≈2.5px, self-correcting).
- **Refuted suspect**: host does NOT throttle cursor reports by time (3px gate, no time window) — "raise the rate" was the wrong lever; ordering (#2) was.
- **Deferred → roadmap**: suspect #4 — `ZoomGeometry.renderScale` computed through `frameViewport` steps the scale at each re-crop (spring animates a "pop"). HIGH-RISK (zoom math) → land a pure bit-stability test first, only after device confirms the pop. Roadmap Now `[ ]`.
- **glm-5.2 first dispatch** (provisional T2 → now evidence-backed): strong tool-enabled review, matched Opus's read exactly (double-guard, drain trace, ε bound). 1 useful nit applied (explicit `.unbounded` AsyncStream buffering); 2 rejected (dead-code claim WRONG — definite-init for `[weak self]`; "test not CLI-visible" — runs under xcodebuild). Scorecard updated (2026-06-19).
- Verify: `swift test` **129/37**, iOS `xcodebuild test` **43**, macOS **BUILD SUCCEEDED**. NOT pushed.
- NEXT (human device verify): high-zoom pan smooth, no periodic hitch; cursor tracks 1:1 without rubber-banding/back-stepping. Watch for a render-scale "pop" at re-crops (→ deferred #4). Then the still-pending device-verifies (M7, magnifier crash landmine, SAS pairing security review).

## Previous Session (2026-06-16 #2 — magnifier crash-hardening, discrete capture-size ladder)

- Ultracode multi-model: 5-model adversarial AUDIT (haiku, sonnet, minimax-m3, qwen3.7-max, kimi-k2.7-code) of the magnifier path → fix → tool-enabled adversarial REVIEW. De-risks the rapid-zoom CRASH landmine. Build-green; **device-verify pending**. Decision: decisions.md (2026-06-16 top); roadmap Now `[x]`.
- **Root cause**: mult-of-16 output snap = ~215 distinct sizes on a 3440px display → continuous pinch tore down/rebuilt the VideoToolbox encoder + reconfigured SCStream on nearly every step (the historical crash shape).
- **Fix**: `CaptureSizing.snapCropFraction` — snap the captured region SIZE onto a coarse geometric ladder (ratio 0.8, ~13 rungs), snapped UP so it still ⊇ the requested window. `setViewport` captures the snapped region (recentered, clamped) + sizes the encoder output from the SAME fraction (buffer aspect == captured-region aspect, no stretch). Host ECHOES the snapped region → client `frameViewport` stays aligned. Reconfigure only at rung crossings (~13 vs ~215).
- **Also**: config save/restore on `updateConfiguration` failure (desync→wedge); `encoder = nil` on encode failure (wedged-VT spin); stale `ZoomGeometry` doc-comment.
- **Audit false positives I rejected** (verified against the per-connection serialized inbound loop): the "config reference-type race" (Sonnet+Haiku both over-flagged critical; qwen correctly refuted) and `.zero` sourceRect (Apple full-display sentinel). Sonnet's tool-enabled review PROVED the snap/clamp safety invariant + found one real near-full seam (fixed).
- **Scorecard signal**: cheap pi models (qwen3.7-max, minimax-m3) out-accurated the native subagents on this concurrency audit; qwen3.7-max added to the roster. Harness reliability lessons: kimi needs `-p @file` (not huge inline `-p`); qwen needs tools (not `--no-tools`). See `~/.claude/model-scorecard.md`.
- New tests: `CaptureSizingTests` (ladder discreteness/idempotency/monotonic/aspect/stability). Verify: `swift test` **125/36**, iOS **38**, macOS **BUILD SUCCEEDED**. NOT pushed.
- **Follow-up #2 (device feedback)**: high-zoom pan repaint was laggy (only repainted after the cursor stopped, then ~1s). Cause: the magnifier follows the host cursor but the crop re-request was an IDLE DEBOUNCE (fired 250ms after stop) + tiny 8% padding. Fix: `ViewportRequestScheduler` → **leading+trailing throttle** (150ms, tracks during motion — safe now that pan re-crops are sourceRect-only/no encoder rebuild); `ZoomGeometry` padding 0.08→0.25. Tests: throttle leading/burst/reset/near-dup green; iOS TEST SUCCEEDED. Decision: decisions.md (2026-06-16 top). Device-verify: pan repaints AS you move; watch for new keyframe-stutter (~6/s) → raise interval or drop pan keyframes if so. (Disk filled mid-session — user cleared `/tmp` build dirs.) Follow-up fix: qwen review caught a real latency bug — `flush()` reset the throttle window on sub-epsilon jitter (before the near-dup guard), deferring the next real move up to a full interval; moved `lastFire` to fire only on an actual send + regression test.
- **Follow-up (same session)**: killed the echo/frame race qwen flagged — every `VideoFrame` now carries its region (4 normalized UInt16, full defaults); client sets `frameViewport` from the rendered frame (atomic, change-guarded); removed the standalone `.viewport` echo. Spec'd by Opus → Sonnet impl → qwen+Opus review (2 findings applied: 60Hz churn guard + dead-case comment; 4 false-positives confirmed wire symmetry/clamp/Equatable). Residual ≤2-frame capture-vs-encode skew deferred (inherent to SCStream). Verify: `swift test` **126/36**, iOS **38**, macOS **BUILD SUCCEEDED**. Decision: decisions.md (2026-06-16 top).
- NEXT (human device verify): **rapid pinch zoom in/out repeatedly → must NOT crash** (the whole point); ~5× text crisp; zoom continuous despite discrete crispness rungs; pan smooth; no blip at rung crossings (if there is one → capture-time frame tagging). If notchy → densify ladder; if soft → raise cropped bitrate. Then the still-pending M7 device-verify + SAS pairing security review.

## Previous Session (2026-06-16 — M7: host presence & frictionless connect)

- Big milestone, ultracode multi-phase (design workflow → implement → adversarial-review workflow → fix). Build-green; device-verify pending. Decision: decisions.md (2026-06-16 top); roadmap Now `[x]`.
- **P1 menu-bar host**: `MenuBarExtra(.window)` beside the WindowGroup (id "main"), shared `@State HostAppModel`; `MenuBarHostView` (status/QR/copy/count/Start-Stop/Open-window); pure tested `HostMenuBar.symbol`. Hosting now outlives window-close (removed WindowGroup `onDisappear{stop}`).
- **P2 live permissions onboarding**: real `CGPreflightScreenCaptureAccess` + `AXIsProcessTrusted` bools on `HostAppModel`, 2s **app-lifetime** poll (not window-scoped); pure tested `PermissionsOnboarding` + guided banner (Open Settings/Re-check + Screen-Recording-relaunch caveat); replaced inferred `PermissionStatus`.
- **P3 input serialization**: `OutboundInputPump` ordered FIFO lane per connection (queue+wake) with **pointer-move coalescing** (summed deltas) — discrete events ordered/lossless; bound/unbound at every connection site. Helps the choppy-drag report.
- **P4 SAS pairing**: design spec only (`docs/superpowers/specs/2026-06-15-sas-pairing-design.md`) — **awaiting human security review**, not implemented.
- Review 5/5 fixed: pointer-move coalescing (the lurch); `isRunning` → observed stored bool (menu glyph/Start-Stop went stale when serve loop ended while ready); permission monitor moved off window lifecycle → app-lifetime (3 LOWs).
- New tests: HostMenuBar(5), PermissionsOnboarding(4), OutboundInputPump(2). Verify: `swift test` **122/36**, iOS **38**, macOS **BUILD SUCCEEDED**. NOT pushed.
- NEXT (human device verify): menu-bar QR/connect; grant Accessibility → dot flips ≤2s (Screen Recording → relaunch); drag smoother + glyph/Start-Stop update on session end. Then the still-pending magnifier device-verify (crash landmine) + bitrate/persistence/file-transfer checks. SAS pairing needs security review before build.

## Previous Session (2026-06-15 #4 — magnifier region-streaming rework)

- Implemented THE high-zoom blocker fix (build-green; **DEVICE-VERIFY REQUIRED**, crash landmine). Decision + spec: decisions.md (2026-06-15 top) + docs/superpowers/specs/2026-06-15-magnifier-region-streaming.md. Roadmap Now `[x]`.
- Root cause: square crop (`max(visW,visH)`) + display-sized output ⇒ host never cropped for an ultrawide-on-portrait ⇒ digital-zoom blur. Fix: client `cropRequest` = visible window's own aspect (not square); host `setViewport` sets `sourceRect` AND `config.width/height` = crop pixels (`CaptureSizing.cropOutputSize`, mod-16/capped/floored, changes only on zoom not pan); client render uses FRAME aspect (`frameAspect = (f.w/f.h)*displayAspect`). Zoom-1 path mathematically unchanged (no regression).
- New tests: `ZoomGeometryTests` (5), `CaptureSizing.cropOutputSize` (3). Verify: `swift test` **113/34**, iOS **36**, macOS **BUILD SUCCEEDED**. Host rebuilt + relaunched for the user.
- Also roadmapped (user ideas this session): **menu-bar host** (`MenuBarExtra` — open for QR / OTP button) + the **6-digit OTP** pairing (both Next).
- NEXT: USER device-test the magnifier (~5× → crisp, pan smooth, zoom-1 unchanged, **watch for crash** on rapid zoom). If it stutters on zoom steps → the "discrete output sizes" follow-up (roadmap Now).

## Previous Session (2026-06-15 #3 — device test feedback + bitrate-default fix)

- User device-tested the new build (3440×1440 ultrawide host + portrait iPhone). Findings → roadmap Now/Next.
- **Fixed now**: bitrate default regression — quality-controls defaulted to 25 Mbps (below the host's prior ~80 Mbps heuristic). Now client default = **Auto** (`bitrateMbps=0` → `targetBitrate=0` → host heuristic); slider 0(Auto)–80 overrides. iOS tests 23, green. (Tell user: in Settings leave Auto or crank to 80 + reconnect.)
- **Mouse not moving** = Accessibility not granted (user fixed it). Not a bug.
- **THE blocker (roadmap Now)**: high-zoom blur/distortion — diagnosed: `ZoomGeometry.cropRequest` square `max(visW,visH)` ⇒ for an ultrawide on a portrait phone the window stays full-height ⇒ host never crops ⇒ digital zoom into a full low-bitrate frame. Real fix = region streaming (crop sourceRect to the visible window + resize encoder OUTPUT to the crop aspect; landmine: prior tight-crop attempt crashed/stretched, decisions 2026-06-04). `complexity: L`.
- Roadmap Now also: **motion choppiness** on pan/move. Roadmap Next: **6-digit OTP pairing** for Bonjour-discovered Macs (user request; QR still preferred).
- NEXT: take on the magnifier region-streaming rework (device-verify each step with the user) — it's what makes high-zoom usable.

## Previous Session (2026-06-15 #2 — three device-testable features: DONE, build-green)

- "Burn through real features" → shipped 3 (build-green; device-verify pending). Decision: decisions.md (2026-06-15, top entry); roadmap Now `[x]` + Next items marked done.
- **Quality controls**: host now HONORS client bitrate/fps (was hardcoded 60fps + heuristic — ignored the request). New `StreamParameters` (clamps) in HostCore; `HostRunner` threads requested fps/bitrate into capture + encoder. Client `ClientSettings` (persisted) + Glass **Settings** sheet (gear on Deck Home: bitrate 4–80 Mbps, fps 30/60, Forget-all, version), read at handshake. ⭐ the real crispness knob.
- **Endpoint persistence**: `PortviewConnection.resolvedRemoteEndpoint`; `SessionViewModel` publishes `connectedHostToSave` (resolved IP) → unified remember-on-stream in ContentView. `SavedHostsStore.upserting` matches name→host:port→pin. Retired `PairingCoordinator` (+test). Fixes: discovered Macs persist; moved Mac's IP refreshes.
- **Mac→iPhone file transfer**: host "Send a file" card (NSOpenPanel) → `HostControl.sendFile(to: sessionID)`; client `IncomingFileTransfers` streams chunks to a per-transfer temp dir → `ReceivedFile` → `ShareLink`. Completes M5 both ways.
- Security: path-traversal in the received filename → sanitized to safe last-path-component at offer time (TDD'd). 3-dim adversarial review: 6/6 confirmed, ALL fixed (OOM→stream-to-disk; reconnect partial-state reset; sendFile target by id; manual/Bonjour dup→pin tiebreaker; temp aliasing→per-transfer dir; disconnect dropping received file→clear on start()).
- TDD added: `StreamParametersTests` (6), client `GlassMappingTests` grew to 21 (settings/hostPort/upsert/file/safeFilename). Verify: `swift test` **110/34**, iOS `xcodebuild test` **31/31**, macOS **BUILD SUCCEEDED**. NOT pushed.
- NEXT (human device verify, see roadmap Now device-verify comment): bitrate knob's visible effect; discovered-Mac persistence across relaunch; IP refresh after a move; a round-trip file send. Product-test checklist published to harness-deck.

## Previous Session (2026-06-15 — Glass HUD redesign, both apps: DONE, build-green)

- Implemented the locked **Glass HUD** design (claude.ai/design handoff, fetched via the share URL → gzip bundle in /tmp/portview_glass) in SwiftUI. All 6 iOS screens + 3 macOS host states. Decision: decisions.md (2026-06-15); roadmap Now `[x]`.
- New files — iOS: `GlassTheme/TelemetryReadout/QualityPanel/ConnectingView/DeckHomeView/PairView/LiveHUDView` (+ `ContentView`/`SessionViewModel`/`SavedHostsStore` rewrites); macOS: `GlassTheme/QRCodeView` (+ `ContentView`/`HostAppModel`/`PortviewHostApp`); core: `HostSessions` (+ `HostRunner` events/`HostControl`). Fonts = System SF + SF Mono; Material glass (not Liquid Glass); real CoreImage QR.
- Built the 2 states needing real new surface: iOS `.reconnecting` + bounded mid-session Bonjour re-bind; macOS live device/stats (HostRunner emit → HostSessions reducer → HostAppModel) + real Disconnect (`HostControl`, sends `.bye`). No fabricated data (latency omitted, not faked; log filters CLI artifacts).
- TDD: `GlassMappingTests` (8, iOS) + `HostSessionsTests` (10, core). 4-dim adversarial review = 9/9 confirmed → 5 fixed (host-`.bye` eviction, atomic click, toolbar order, `TimelineView` mm:ss, per-connection-UUID identity), 2 deferred (roadmap Next: resolved-endpoint infra), 2 no-action.
- Verify: `swift test` **104/33**, iOS `xcodebuild test` **17/17**, macOS `xcodebuild` **BUILD SUCCEEDED**, CLI builds. NOT pushed (per convention).
- NEXT (human device verify): the Glass look on-device; live IP-change reconnect (degraded→reconnecting→live); host state C with a real connected iPhone (name, ticking mm:ss, stats, Disconnect). Plus the still-pending earlier device tests (restart pin/port, HUD/QUIC).

## Previous Session (2026-06-14 — IP-stable saved-Mac reconnect: DONE, build-green)

- Client-only follow-up to the 2026-06-13 work: a saved Mac now reconnects after a LAN IP change (DHCP). Commit `4fe9d79`. Decision in decisions.md (2026-06-14).
- `SavedHost.reconnectEndpoints(among:)` → ordered candidates: name-matched live Bonjour endpoint first (re-resolves current IP), saved `host:port` fallback. `SessionViewModel.run(endpoints:)` tries until the pinned handshake succeeds (initial connect only). `ContentView` saved-Mac tap passes `discovery.hosts`. Pin unchanged → cert pinning still gates (Bonjour name = routing hint only).
- TDD (RED→GREEN). 3-dim adversarial review (8 confirmed): accepted 2 cheap coverage tests (manual-IP fallback, duplicate-name single-endpoint); rejected the rest with rationale (cancellation not a regression; saved-IP-refresh is the deferred follow-up; run-loop mock tests = YAGNI). See decisions.md.
- Verify: `xcodebuild test PortviewClient` (iOS sim) = **9/9**, `** TEST SUCCEEDED **`. Host SwiftPM/packages untouched (still 94/32 from prior session).
- DEFERRED follow-up (roadmap Next): refresh the stored fallback IP after a Bonjour reconnect (needs `PortviewConnection` to expose the resolved remote endpoint).
- NEXT (human device verify): the 2026-06-13 restart test, PLUS — pair, change the Mac's LAN IP (or rejoin Wi-Fi), reconnect from Saved Macs without rescanning → should connect via Bonjour. Then the still-pending HUD/QUIC device tests (roadmap Now).

## Previous Session (2026-06-13 — persistent host identity + stable port: DONE, build-green)

- Resumed from Codex's state (build-green at `7e2bc07`); implemented **persistent host identity + stable port** end-to-end. Spec `909c2a8`, impl `e1a9db4`. Decision in decisions.md (2026-06-13).
- `TLSIdentity.loadOrCreatePersistent`/`persistPort`: openssl p12 blob + bound port as one Keychain generic-password item; re-import on launch; re-mint absent/expired (cert `-days 2`→3650, <30d threshold); ephemeral fallback on Keychain failure. `PortviewListener` optional `port:`. `HostRunner` re-binds persisted port (fallback if taken) + surfaces non-persistence/port-fallback via `HostRunnerEvent.message`. App + CLI use DISTINCT Keychain items.
- TDD throughout (RED→GREEN each). 15-finding adversarial multi-agent review applied (app/CLI service split was a real critical; errSecDuplicateItem, listener-leak, process lock); 2 findings rejected with rationale (see decisions.md).
- Verify: `swift test` = **94 tests / 32 suites**; `swift build --product portview-host`; `xcodebuild PortviewHost` (macOS) BUILD SUCCEEDED; `xcodebuild PortviewClient` (iOS sim) BUILD SUCCEEDED. Real `KeychainIdentityStore` round-trip test passed (keychain usable under `swift test` here).
- NEXT (human device verify): launch `PortviewHost.app`, pair from client, **restart the app**, reconnect from Saved Macs without rescanning → expect same pin + port. Then resume the still-pending HUD/QUIC device tests (roadmap Now).

## Previous Session (2026-06-11 — macOS host app)

- Added `PortviewHostCore` shared library; moved host runtime out of CLI so both CLI and app use the same ScreenCaptureKit/QUIC/session code.
- Added XcodeGen macOS `PortviewHost.app` target (`dev.finklea.portview.host`) with SwiftUI status window, Screen Recording/Accessibility settings links, pairing details, and copy pairing URL.
- CLI `portview-host` remains a thin developer fallback; its Screen Recording help now points normal device testing at `PortviewHost.app`.
- Review follow-up: Stop Hosting now cancels structured per-client session tasks and closes connections; app plist declares `NSLocalNetworkUsageDescription` + `_portview._udp` Bonjour service.
- Verify: `swift test --package-path /Users/tfinklea/git/screenshare` → 82 tests / 28 suites; `swift build --package-path /Users/tfinklea/git/screenshare --product portview-host` → complete; `xcodegen generate` in `apps/PortviewHost`; generated plist contains local-network/Bonjour keys; `xcodebuild build -project apps/PortviewHost/PortviewHost.xcodeproj -scheme PortviewHost -destination 'platform=macOS'` → BUILD SUCCEEDED. Manual next: launch app, grant Screen Recording to Portview Host.app, then continue HUD/motion retest.

## Previous Session (2026-06-10 — motion debounce follow-up)

- User retest after `3d8309b`: rendering quality back to prior baseline, but motion jerkiness worse.
- Root-cause hypothesis: client still sent viewport/crop requests during continuous pointer movement; host `SCStream.updateConfiguration` + keyframe requests can stutter the interactive path.
- Implemented `ViewportRequestScheduler`: 250 ms latest-only idle debounce, reset cancellation, near-duplicate suppression; `SessionViewModel` delegates host crop requests to it.
- Verify: `swiftc -typecheck apps/PortviewClient/Sources/ViewportRequestScheduler.swift`; `git diff --check`; `swift test --package-path /Users/tfinklea/git/screenshare` → 76 tests / 27 suites; `xcodebuild test -project apps/PortviewClient/PortviewClient.xcodeproj -scheme PortviewClient -destination 'platform=iOS Simulator,name=iPhone 17'` → 4 tests; Roshar device build → BUILD SUCCEEDED; `devicectl` installed `dev.finklea.portview`.
- Caveat: device build still emits existing warnings: `UIScreen.main` deprecated in `MetalVideoRenderer.swift`; interface orientations validation.

## Previous Session (2026-06-05 — persistent pairing + motion rollback)

- Fixed saved pairing persistence for QR/manual reconnects: new `PairingCoordinator` keeps pending payload outside the connect form; streaming view commits only after `.streaming`, so view replacement no longer drops the save.
- Saved Macs section now appears before QR pairing; tapping a saved Mac reconnects with stored host/port/cert pin and re-saves on success to keep it most-recent.
- Added `PortviewClientTests` XcodeGen unit-test target + `PairingCoordinatorTests` (red: missing coordinator; green after implementation).
- Device build for `Roshar` → BUILD SUCCEEDED; installed `dev.finklea.portview` via `xcrun devicectl`.
- User reported the high-res/quality-hint build looked less smooth and jerky. Rolled back interactive capture output to display-point dimensions and removed VideoToolbox quality-over-speed hints; keep explicit bitrate heuristic.
- Verify: `swift test --package-path /Users/tfinklea/git/screenshare` → 76 tests / 27 suites green. `xcodebuild test ... -destination "platform=iOS Simulator,name=iPhone 17"` → 1 test green.
- Caveat: motion rollback is host-side; restart `portview-host` before retesting. Host identity is still ephemeral per server run; saved pairings are valid while the same host process/port/cert is running.

## Previous Session (2026-06-05 — video quality diagnostics)

User device-tested latest app: zoom is better but still softer/blurry vs VNC. Chose instrumentation before more features.

- Added `QualityStats` protocol msg (19) + tests; host emits ~1 Hz encoder stats: configured bitrate, actual encoded Mbps/fps, avg bytes/frame, keyframes, avg encode ms, encoder dimensions, active viewport.
- Client computes receive Mbps/fps, bpp/frame, avg decode ms, frame size; streaming toolbar gauge toggles a compact Quality HUD.
- Metal renderer now has runtime sampler toggle (Linear ↔ Nearest) while HUD is visible; use this to distinguish encoded softness from final texture filtering.
- ON-DEVICE HUD #1: Linear looked better than Nearest, but still smoothed. HUD showed the real issue: `Enc 1710x1107 @34 Mbps`, Host/Recv only `~0.06 Mbps`, `~886 B/f`, and at 4x zoom `Crop w1.00 h1.00` / `Frame w1.00 h1.00` → pure digital zoom into a low-res/full-frame source; host magnifier was not helping.
- Follow-up #1: crop padding tightens at high zoom, crop changes force next frame keyframe, max zoom 6x, HUD bpp precision 4 decimals. Verify: 74 tests / 26 suites; iOS sim build green.
- ON-DEVICE HUD #2: crop now moves, but not enough: `Crop x0.00 y0.02 w0.93 h0.93`, `Frame x0.00 y0.02 w0.93 h0.93`; encoder still `1710x1107 @34 Mbps`, actual `~0.05 Mbps`, `810 B/f`, `bpp 0.0034` → CoreGraphics backing-pixel probe did not raise ScreenCaptureKit output.
- Follow-up #2: SDK headers show `SCDisplay.width/height` are points; `SCContentFilter.pointPixelScale` is the scale. Tried `SCStreamConfiguration.width/height = display points * filter.pointPixelScale` plus encoder quality hints.
- ON-DEVICE HUD #3: high-res/quality-hint build looked less smooth and jerky. Latest session reverted interactive output to display-point dimensions and removed quality-over-speed hints.
- Next device run after restarting host: confirm smoothness returns, then record HUD Host/Recv Mbps, B/f, bpp, Crop/Frame. If soft but smooth, tune effective crop + bitrate/adaptive rate next; do not re-pursue full-frame Retina output as the default interactive path.

## Previous Session (2026-06-02 #3 — QUIC swap + zoom fixes)

User confirmed all "do all of it" features work on device. Then: "switch to QUIC and actually test it" + "zoomed-in experience is still terrible."

- **QUIC is now the DEFAULT transport** (commit `beced46`). Ran a 6-candidate empirical loopback sweep (parallel worktrees). Breakthrough: the `NWConnectionGroup`/`NWMultiplexGroup` model was a **red herring** — a bare `NWConnection(to:using:QUICParameters.client)` is itself one bidirectional QUIC stream and carries a full round-trip. The real gotcha is QUIC's server-side **double-delivery** (`newConnectionHandler` fires twice: a dead "control" connection + the real data one) — fixed by the host serving each accepted connection **concurrently** (`Task { serve }`). Client uses `connectQUIC`, host uses `PortviewListener(quicIdentity:)`. Dead multiplex scaffolding removed. Bonjour type → `_portview._udp` (+ NSBonjourServices). `QUICBidirectionalTests` ENABLED + green. TLS-over-TCP kept as one-call fallback. See decisions.md ADR. **Tests 70/25 green; host + iOS build clean.** ⚠️ QUIC not yet validated on a real/Tailscale link (only loopback) — needs on-device test.
- **Zoom — jumpy + off-center FIXED** (commit `689b253`, client-only): off-center was a real bug (pan math centered against full view bounds, ignoring the Metal letterbox) — now centers against the actual aspect-fit video rect with correct clamping; jumpy → short critically-damped spring on the pan offset. Verified iOS build.
- **Zoom — blurry = FIXED via host-side magnifier** (commit `235bb88`, user chose "build full magnifier now"). New `Viewport` msg (18, normalized, both directions): client sends target crop (1/zoom, cursor-centered, throttled ~12 Hz); host sets `SCStreamConfiguration.sourceRect` to it (output dims constant → region encoded at full res → crisp) and confirms when applied. Client renders a **residual** transform (residual zoom = frameViewport.w / target.w) → instant digital zoom during the pinch that settles to crisp host-cropped 1:1 when frame==target. Adversarial multi-agent review (12 agents) found+fixed 4 real issues: setViewport is `async -> Bool` awaited in-order in the inbound loop (no orphaned/racing confirm Tasks), confirms only on updateConfiguration success (no phantom-crop settle), dedup+1% near-full threshold (no reconfig thrashing). **Tests 72/25 green; host + iOS build clean.**
  - **ON-DEVICE (user, 2026-06-03):** "a lot better… usable." Reported 3 limitations → all addressed in the **zoom overhaul** (commit `fad89a6`, build-green, device-verify pending):
    - **#1 aspect/fill:** new `ZoomGeometry` **window model** — view-aspect window sized by 1/zoom; zoom 1 = whole display (overview, unchanged), zooming shrinks the window toward the phone aspect so the **letterbox bars shrink to none**. Rendered via uniform renderScale+pan mapped through the host crop (re-crop changes crispness, not position → no jerk; continuous from zoom-1, no jump). Chose this over the two-mode view-aspect host output (smoother, no rebuild churn).
    - **#2 jerky:** visual decoupled from host re-crop; crop padded 1.4×; throttle 80→120 ms.
    - **#3 pixelated:** `VideoEncoder` now sets an explicit AverageBitRate (w·h·6, 8–50 Mbps; set none before → soft default).
    - Adversarially reviewed (no geometry bugs).
  - **ON-DEVICE #2 (user, 2026-06-03):** fill works great, but still blurry at moderate zoom. Tried tight-crop/native-res host output (`4591ef7`) — **it "looked worse" on device + the host CRASHED**, so:
  - **ON-DEVICE #3 (user, 2026-06-04):**
    - **CRASH FIXED** (`d6996bd`): `ClipboardSync` polled `NSPasteboard` on a background Task thread → AppKit memory corruption (`pointer being freed was not allocated` → SIGABRT at ClipboardSync.swift:22). Fix: all NSPasteboard access on the **main actor** (`Task { @MainActor in }`). *(Latent since the clipboard feature; fired when the pasteboard changed during a session.)*
    - **Tight-crop REVERTED** (`e02482e`): post-mortem — the blur is **bitrate-bound, not resolution-bound**. The whole display was encoded at native res but ~0.1 bpp (soft text); the tight crop shrank buffer + bitrate proportionally so bpp didn't improve, and re-encode churn made it worse. Back to the known-good window model.
    - **Crispness fix that shipped** (`5b11c69`): raised encoder bitrate ~0.1→~0.3 bpp (w·h·18, clamp 12–80 Mbps) — LAN/QUIC has bandwidth to spare; the full display is encoded crisper and the client digitally zooms in. Tunable on device.
    - **Tests 72/25 green; host + iOS build clean.** Device-verify pending. Further crispness lesson in roadmap: keep bitrate HIGH while cropping (per-region rate), don't scale it down with the buffer.

## Previous Session (2026-06-02 — "do all of it")

Worked the full remaining backlog sequentially. **All 9 items done + committed** on top of the hardware-verified POC. **Tests: 69 / 24 suites green (1 QUIC test intentionally disabled). Host builds clean. iOS app BUILD SUCCEEDED.**

- **Clipboard sync (M2)** — `ClipboardUpdate` msg (13); host `ClipboardSync` polls NSPasteboard changeCount → push, applies remote without echo; client writes UIPasteboard inbound + "paste to Mac" button. Commit `0865234`. *(Also fixed a real bug: host input case list was missing `.keyEvent` → backspace/return/arrows were never injected.)*
- **Modifier keys / chords (⌘⇧⌥⌃)** — `KeyModifiers` OptionSet; `KeyEvent` carries modifiers + either a SpecialKey OR a character (⌘C works). Host CGEventFlags + ANSI/US keycode table. Client sticky modifier bar (arm → next key is a chord → auto-clears). Commit `624d821`.
- **2-finger scroll vs pinch-zoom** — per-gesture intent-lock in `TrackpadVideoView.Coordinator` (first decisive signal wins; loser no-ops until fingers lift; baselines rebased). Commit `9b23eed`.
- **Saved-Macs list** — `SavedHostsStore` (UserDefaults JSON); "Saved Macs" section (one-tap reconnect, swipe-delete); persisted only on `.streaming` (never a bad pin). Commit `997972b`.
- **Multi-monitor (M3)** — host advertises ALL displays in ServerHello, picks by StartSession.displayID; new `SwitchDisplay` msg (14) re-targets capture + rebinds InputInjector live; pumpVideo breaks on cancel. Client display-switcher Menu. Commit `23bc418`.
- **File transfer (M5)** — iPhone→Mac push; `FileOffer`(15)+`FileChunk`(16); host `FileReceiver` writes ~/Downloads (de-dups names); client `.fileImporter` + 64 KB ordered chunks interleaved with video. Commit `614dd39`. *(Mac→iPhone = future.)*
- **Metal renderer** — replaced AVSampleBufferDisplayLayer with explicit `VideoDecoder` (HEVC→BGRA) → `MetalVideoRenderer` (CVMetalTextureCache zero-copy → CAMetalLayer, runtime passthrough shader, aspect-fit). Commit `b2c14f2`.
- **Audio (M4)** — SCStream `capturesAudio`; host converts to non-interleaved Float32 (AVAudioConverter), `AudioFrame`(17); client `AudioPlayer` (AVAudioEngine/PlayerNode). Commit `3dceb0e`. *(Plays as it arrives; tight A/V lip-sync = future.)*
- **QUIC transport (M6) — GROUNDWORK ONLY, not a swap.** Additive `connectQUIC` + `PortviewListener(quicIdentity:)` via NWMultiplexGroup; cancellable `awaitReady`. Loopback bidi test `@Test(.disabled)` because it **reproduced the documented chicken-and-egg** (ready-before-open hangs; open-immediately returns nil/`streamUnavailable`). TLS-over-TCP remains the shipping default — zero regression. See decisions.md ADR. Commit `e441244`.

**⚠️ Not yet hardware-verified (build-green only):** clipboard, modifiers, gestures, saved-Macs, multi-monitor, file transfer, **Metal render path** (replaced the proven AVSampleBufferDisplayLayer — check video still paints on device), and **audio** (needs device + Screen-Recording grant + real audio source). Re-run host (`swift run portview-host`, grant Screen Recording) + rebuild client on device to validate.

## Last Session Summary

**Date**: 2026-06-02

- Brainstormed Portview from scratch (greenfield). Locked all product decisions (see `decisions.md`).
- Ran a 70-agent research workflow on Apple screen-sharing protocols / capture / iOS / transport / prior art; it validated the own-host-agent + QUIC + HEVC direction.
- Wrote canonical design spec: `docs/superpowers/specs/2026-06-02-portview-design.md`.
- Scaffolded repo: LICENSE (Apache-2.0), README, .gitignore, `.docs/ai/`.
- Next: writing-plans → implement M0 (PortviewProtocol package, TDD).

## Build Status

- 🎉 **HARDWARE-VERIFIED 2026-06-02:** full POC works on a real iPhone → Mac — live HEVC screen repainting **and** trackpad control (move/click/scroll via CGEvent), connected via QR pairing. M0 + M1 confirmed end-to-end on device. (Bug found & fixed during the live run: encoder must match the capture buffer's pixel size, not `display.width` points — Retina mismatch was dropping every frame; commit `7752b61`. Accessibility + Screen-Recording grants both working.)
- **Keyboard typing + pinch-zoom-follows-cursor IMPLEMENTED + compiling (55 tests / 19 suites):** protocol gained `KeyEvent` (special keys: return/delete/tab/escape/arrows) + `CursorPosition` (host→client, normalized). Host `InputInjector` injects special keys (CGEvent virtualKey) and reports cursor position (throttled). Client: on-screen keyboard via a `UIKeyInput` first-responder (insertText→typeText, deleteBackward/return→KeyEvent) toggled by a toolbar button; pinch-to-zoom on the video with a clamped layer transform that keeps the host cursor centered when zoomed. NOT yet hardware-verified (restart host + rebuild client to try). Note: zoom cursor-follow approximates the cursor in view-bounds space (ignores letterbox) — refine if off.

- Toolchain: Swift 6.2, Xcode 26.0.1, macOS 26.3.1 (Apple Silicon). Confirmed.
- `PortviewProtocol` package: builds clean, `swift test` = 31/31 green (9 suites). Wire protocol complete — binary primitives, 6 M0 messages, self-delimiting framing, FrameDecoder stream reassembly, client/server handshake state machines, e2e handshake-over-frames. (Plan: `docs/superpowers/plans/2026-06-02-portview-protocol.md`, executed.)
- `PortviewTransport`: IMPLEMENTED. 36 tests / 13 suites all green. TLS identity (RSA self-signed via openssl→PKCS#12→SecPKCS12Import), QUIC loopback spike (one-way, proves QUIC works), cert pinning (SHA-256 of leaf DER), MessageChannel, and `PortviewConnection`/`PortviewListener` carrying the full handshake + a VideoFrame over a real localhost connection.
- **POC transport = TLS-over-TCP** (see decisions.md): bidirectional, unambiguous; QUIC's bare-NWConnection+listener model double-delivers connections and the reply-send hangs (needs the NWConnectionGroup/NWMultiplexGroup multiplex model, deferred). PortviewConnection is transport-agnostic, so swapping back to QUIC is one line. QUICParameters + the QUIC loopback spike remain as proven groundwork.
- `PortviewMedia`: IMPLEMENTED + the **core pipeline POC passes**. VideoToolbox hardware HEVC encode + decode (synthetic-frame round-trip recovers color), HEVC sample serialization (parameter sets + AVCC data ↔ bytes), and a full end-to-end test: frame → encode → serialize → VideoFrame over pinned-TLS PortviewConnection → deserialize → decode → color verified. All autonomous (no TCC/GUI).
- **POC STATUS: the entire core pipeline (encode → secure transport → decode) is proven by tests.** Remaining for a watchable demo (need your hardware): real screen capture (ScreenCaptureKit + Screen-Recording grant), on-screen render (Metal/CAMetalLayer), and packaging the macOS host + iOS client apps (Xcode + device).
- `portview-host` (macOS `swift run` executable): IMPLEMENTED + compiles. CaptureEngine (ScreenCaptureKit SCStream → CVPixelBuffer, drop-stale buffering) → VideoEncoder → VideoSampleSerializer → PortviewListener; does the server handshake then streams VideoFrames; prints cert pin + port. ScreenCaptureKit imported `@preconcurrency` (Apple hasn't Sendable-annotated it for Swift 6). NOT run-verified (needs Screen-Recording grant — `swift run portview-host`, then grant in System Settings, re-run).
- Shared packages gated for iOS: TLSIdentity openssl/Process code is `#if os(macOS)` (client never mints an identity), so PortviewProtocol/Transport/Media compile for iOS.
- iOS client app (`apps/PortviewClient`, xcodegen): SCAFFOLDED + **compiles for iOS 26 simulator (BUILD SUCCEEDED)**. SwiftUI connect screen (IP/port/pin) + SessionViewModel (connect → client handshake → receive VideoFrame → deserialize → enqueue) + AVSampleBufferDisplayLayer renderer. Generated .xcodeproj is gitignored — run `xcodegen generate` in apps/PortviewClient. Run guide: `apps/README.md`.
- **M0 walking-skeleton scaffold COMPLETE and compiling end to end.** Not yet run on real hardware (needs Screen-Recording grant on the Mac + iPhone/Xcode for the client). To watch live: `swift run portview-host` (grant Screen Recording, re-run), then run the iOS app and enter the printed IP/port/pin.
- **M1 control IMPLEMENTED + compiling (full suite 46 tests / 17 suites green):** input protocol messages (pointerMove/pointerButton/scroll/typeText — TDD); host `InputInjector` maps them to CGEvents (relative cursor w/ clamping, click, scroll, unicode type) — host `serve()` now handles input concurrently with the video pump; needs Accessibility grant (host prints a hint). Client: `TrackpadVideoView` — 1-finger drag = move, tap = click, 2-finger = scroll → input messages. iOS app bundle id = `dev.finklea.portview`, automatic signing team K7CBQW6MPG.
- Fixed a flaky `SecPKCS12Import` race under concurrent test suites by serializing it with a lock (`TLSIdentity.importLock`); 3 consecutive full-suite runs green.
- Host needs BOTH grants to fully work: Screen Recording (capture) + Accessibility (input). Both attach to the terminal app for `swift run`.
- **M1 frictionless connect IMPLEMENTED + compiling (50 tests / 18 suites green):** host advertises Bonjour `_portview._tcp` and prints a pairing URL + terminal QR; shared `PairingPayload` (URL ↔ host/port/pin, tested) + `PortviewBrowser`; client gets a discovered-Macs list, a camera QR scanner (scan → auto-connect), and manual entry. iOS Info.plist now has NSBonjourServices + NSCameraUsageDescription + NSLocalNetworkUsageDescription (via xcodegen `info:`; generated `*-Info.plist` is gitignored). *(QR scannability + camera unverified — need a device.)*
- Next: run M0/M1 on hardware; then M1 polish (on-screen keyboard UI, saved-Macs list, device keypairs + revocable PairingStore) and M2+ (clipboard/audio/files/multi-monitor); revisit QUIC + Metal renderer.

## Blockers

- None.

## Verified SDK facts (macOS 26.0 SDK, by reading headers)

- QUIC datagrams ARE supported in Network.framework (`NWProtocolQUIC.Options.maxDatagramFrameSize`/`.isDatagram`/`.usableDatagramFrameSize`; `nw_quic_*` in quic_options.h). BUT: only one datagram flow per connection and frames are MTU-bounded (~1200 B) << a video keyframe. → v1 video lane = one short-lived **unidirectional QUIC stream per frame** (no cross-frame HoL; abandon stale via reset). Datagrams reserved as a future sub-frame optimization.
- Two QUIC API generations exist: classic `NWConnection`/`NWListener` + `NWProtocolQUIC.Options` (chosen for v1 — stable, documented) and the new Swift-first `NetworkConnection`/`NetworkListener` + `QUIC`/`QUICDatagram` builders (future swap, insulated behind our own transport types).

## Open questions (resolve during build)

- ~~iOS 26 QUIC datagrams?~~ RESOLVED: supported; not used in v1 (see above).
- Exact `SecIdentity` self-signed creation + `NWMultiplexGroup` stream-open signatures on macOS 26 → verify in transport Task 1 spike (do not prescribe from memory).
- `EnableLowLatencyRateControl` covers HEVC on macOS 26? (else pin H.264 for low-latency path) — resolve when building the host encoder.

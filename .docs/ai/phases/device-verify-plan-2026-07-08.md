# Consolidated device-verify session (2026-07-08 plan)

> One hardware session (you + Roshar + the Mac) clears all 12 human-gated beads.
> Ordered so shared setups overlap and long waits run in the background.
> After each leg: `bd close <ids> --reason "…"` — closing 89q unblocks 2ee, closing
> pkb unblocks 2ws, closing w6n's parents later gates phase 2.
> On any FAILURE: leave the bead open, `bd create` the finding (reference the bead id +
> what you saw), and move on — don't debug mid-session.

## Prep (~15 min, do first)

- [ ] Rebuild host; **quit the running PortviewHost first**, then `ditto <build>.app /Applications/PortviewHost.app` (stable path keeps TCC grants — never run from /tmp).
- [ ] Rebuild + install the client on Roshar (latest main).
- [ ] Both on the same LAN; Tailscale available for Leg 5.
- [ ] Optional for Leg 4: System Settings → set display-sleep to 1–2 min now (restore after).

## Leg 1 — desk quick wins (LAN, ~15 min)

**er1 — menu-bar host + permissions onboarding.** Open the menu-bar item → QR + Start/Stop + Open window present. Revoke+re-grant Accessibility → status dot flips ≤2 s (Screen Recording needs a relaunch — expected). Glyph/Start-Stop update when a session ends.
**6j7 — SAS pairing (core + HMAC confirm).** Menu-bar → "Pair with a 6-digit code"; iPhone taps the discovered Mac → type the shown code → connects (pinned). A wrong code refuses. Mac briefly shows "✓ a client confirmed". QR path still works.
**43i — quality controls + persistence + files.** Settings: raise bitrate → reconnect → HUD shows higher Mbps + crisper text. Pair a discovered Mac → relaunch app → it's under Saved Macs. Change the Mac's LAN IP (rejoin Wi-Fi) → reconnect → entry refreshes, no duplicate. Host "Send a file" → arrives with a Share sheet.

## Leg 2 — zoom/render cluster (one scenario, five beads, ~20 min)

Use MOVING content (video playing) on the ultrawide, high zoom (~5–6×).

**pkb — crash landmine (do FIRST in this leg).** Rapid pinch zoom in/out repeatedly → MUST NOT crash. ~5× text crisp; zoom continuous despite discrete rungs. If soft → note "densify ladder".
**89q — render pipeline.** High-zoom pan on moving content: no tearing, pan smooth (display-link ease), paints promptly while moving, fps stays high (hysteresis re-crop). Fast cross-screen pans: if fps dips → note "raise ZoomGeometry padX/padY". *(Unblocks 2ee.)*
**b27 — motion/cursor.** Same pans: no periodic hitch; cursor doesn't rubber-band/back-step while dragging. Watch for a render-scale "pop" at re-crops → if seen, that's exactly bead 2ee.
**5ep — CVMetalTexture soak.** Stay in the 89q scenario for several MINUTES: no tearing/garbage frames under sustained load.
**11s — Quality HUD numbers.** While zoomed: record HUD Mbps / bytes-per-frame / bpp + Crop/Frame values. If soft-but-smooth → note numbers for crop/bitrate tuning (feeds 90p/480).

## Leg 3 — peripherals (~10 min)

**ed4 — display refresh.** Connect with one monitor → wake/plug the 2nd display mid-session → switcher reappears ≤~2 s, no host relaunch; switching works.
**36p — audio interruption.** Stream with host audio playing → receive a real call (or Siri) → end it → audio resumes automatically. Also decline a call → no crash.

## Leg 4 — long-wait (start, then leave it)

**1wm — keep-awake + lock overlay.** Client connected, Mac idle past the (shortened) display-sleep timeout → screen stays awake, no idle-lock. Then manually lock → client shows "capture paused" + ALL input disabled; unlock → resumes. Known by-design: manual/policy-immediate lock can't be prevented; no remote unlock.

## Leg 5 — Tailscale (can be a separate sitting)

**ve5 — QUIC over a real link.** Off-LAN via Tailscale: connect/stream/control/clipboard/audio/files all work; note perceived latency + HUD numbers; confirm zoom behaves. (This is also the warm-up for the future lane A/B, bead w6n.6 — but w6n.6 itself waits for the lane implementation.)

## Wrap-up

```
bd close screenshare-er1 screenshare-6j7 screenshare-43i --reason "device-verified 2026-07-XX"
bd close screenshare-pkb screenshare-89q screenshare-b27 screenshare-5ep screenshare-11s --reason "device-verified 2026-07-XX"
bd close screenshare-ed4 screenshare-36p screenshare-1wm screenshare-ve5 --reason "device-verified 2026-07-XX"
```

Then check what unblocked: `bd ready` (expect 2ee, 2ws to surface; tuning notes from 11s/89q go into 90p/2ws).

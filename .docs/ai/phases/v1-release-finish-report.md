# Gate 4 completion report — settings, privacy defaults, first run

> Plan: `docs/superpowers/plans/2026-08-03-settings-onboarding.md`. Rationale: `decisions.md`
> 2026-07-28 and 2026-11-19. This report records what was built and verified. It does not
> repeat the rationale.

**Status: code complete, automated gates green. Named human checks PENDING, so Gate 4 is not
yet marked complete in the master plan.**

## Commits (base `3bd89b1`, branch `codex/v1-release-finish`)

| Task | Commits | Review |
|---|---|---|
| 1 Host preferences + launch-at-login seam | `632acb1` | clean |
| 2 Preferred port / default display | `fde5d38` | clean |
| 4 Clipboard/file opt-in enforcement | `6c46572`, `ae123b7` | clean after 1 fix round |
| 3 Menu bar is the app | `4a50b32`, `5ca2172`, `9f24757` | clean after 2 fix rounds |
| 5 Camera-denied recovery | `cedf7a5` | clean |
| 6 iOS first-run walkthrough | `c4cb311` | clean |
| 7 `portview://pair` routing | `c621785` | clean |
| Final-review fix wave | `2f54a29`, `13aa150` | clean (Sonnet + gpt-6.1-terra re-review) |

Reviews:
- Plan review: gpt-6.2-sol. 17 findings; 15 adopted, 2 partially rejected.
- Per-task: Sonnet reviewer.
- Final: independent Sonnet whole-branch review plus a gpt-6.1-terra diff review. No Critical
  findings. The Important findings were fixed or ruled on (see `decisions.md` 2026-11-19).

## Automated verification

- `swift package clean && make preflight` at `c621785`: exit 0.
  - SwiftPM 810 tests (148 + 149 + 186 + 319 + 8).
  - Mac build and host logic tests: 42.
  - iOS simulator tests: 126.
- Fix-wave head `13aa150`: see `current-state.md` for the final preflight result.

## Named human checks — PENDING (agent cannot run these)

Mac, using `/Applications/PortviewHost.app`:
1. Launches into the menu bar only: no Dock icon, no window.
2. On a fresh Mac, Screen Recording (quit and reopen) and Accessibility can be granted entirely
   from the popover.
3. Popover notices show warnings and failures, e.g. the pairing-store reset result.
4. Launch at login registers and unregisters. "Needs approval" opens Login Items.
5. A chosen free port binds on restart. A taken port falls back without erasing the preference.
6. A remembered display is chosen when present and falls back when absent.
7. A port edit commits on click-away.
8. Turning a privacy toggle on and cancelling Touch ID snaps the switch back to off.
9. "Send a file" opens its picker in front.
10. Quit stays final.

Live privacy, with one paired iPhone connected:
11. Defaults block both clipboard directions and both file directions.
12. Enabling each (Touch ID) permits it.
13. Disabling mid-session stops the next clipboard effect and an in-progress file's next chunk
    without reconnecting.
14. Screen and input keep working throughout.

iPhone:
15. A fresh install shows the walkthrough once; relaunch doesn't repeat it; Settings reopens it.
16. Camera allow scans. Camera deny shows "Camera access is off" with Open Settings and manual
    pairing. After granting in Settings, returning to the screen gives a working scanner.
17. A valid host `portview://pair` URL shows the confirm prompt, and Pair connects. An invalid
    URL, or any URL during a live session, changes nothing.

## Carried forward (deferred minors, non-blocking)

The full list is in the plan's SDD ledger (git-ignored). Notable items:
- ServerHello display list comes from a pre-admission snapshot.
- `sendFile` tests don't isolate its own guards from the sink's.
- Stale partial files linger until the next chunk arrives or the session ends.
- Two clipboard tests depend on timing.
- The iOS client builds in Swift 5 language mode.
- The URL prompt's `name` is attacker-controlled; host:port is always shown.

## Gate 2 interaction

Gate 2 R4 has not been staged yet. Run it on a post-Gate-4 build, and **enable clipboard and
file transfer in the menu bar first**: they now default off.

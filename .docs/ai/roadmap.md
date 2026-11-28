# Roadmap

> Owner-facing: outcomes, priorities and direction. Task state lives in Beads (`bd --sandbox ready`).
> The full v1.0 plan is `docs/superpowers/specs/2026-11-21-v1-production-roadmap-design.md`.
> History up to 2026-11-21 is in `roadmap-archive-2026-11.md`.

## Vision

Portview is open-source, native-feeling iPhone and iPad control of your own Mac: a Mac menu-bar
host (ScreenCaptureKit, hardware HEVC, encrypted QUIC) and a viewer/controller app. No servers we
run. Apache-2.0. macOS 26 and iOS 26, Apple Silicon.

## v1.0 — production ready for anyone on the App Store

Approved by the owner on 2026-11-25. v1.0 ships when all nine hold on the build that ships:

1. A stranger gets from the store listing to a live session without help.
2. Every core feature passes a named device check on the LAN, and a remote subset over Tailscale.
3. It works on iPad, with a hardware keyboard.
4. The Mac host updates itself; a version mismatch says which half to update.
5. Every failure shows what to do next.
6. A user can send a diagnostics file; nothing is sent automatically.
7. The security claims hold on real devices.
8. It survived a public beta.
9. The docs and the listing describe only what was verified.

### Where it stands

| Phase | What | Who | State |
|---|---|---|---|
| 0 | Handoff: roadmap, Beads issues, branch backed up | agent | done 2026-11-25 |
| 1 | Risk check on today's build (six checks) | owner | next (`portview-p1`); checklist ready: `phases/v1-risk-check-checklist.md` |
| 2 | Build: eleven workstreams W1–W11 | agent | ready to start |
| 3 | Release candidate and the full device session | both | waits for Phase 2 |
| 4 | Public beta: Mac download and site first, then TestFlight | both | waits for Phase 3 |
| 5 | 1.0 launch: App Store review, manual release, tag | both | waits for Phase 4 |

Phase 2 workstreams: W1 right-click, actionable errors, finding the Mac app, Mac first launch ·
W2 network-format freeze and compatibility · W3 iPad · W4 Sparkle updates · W5 diagnostics export ·
W6 audio and sync defects · W7 disk image · W8 site, policy and listing · W9 small fixes ·
W10 findings from device sessions · W11 optional tip.

### Waiting on the owner

- The Phase 1 risk-check sitting (`portview-p1`), including the iPad keyboard probe. After it,
  approval to land the release branch on `main` (`portview-own-land`).
- The exact hostname for the site and update feed (`portview-d1`), before the first beta build.
- A public support email address (`portview-d2`).
- Tip amounts, and confirming the tip unlocks nothing (`portview-d4`).
- Later: the update-signing key, the App Store Connect agreements and tip products, publishing the
  site, one uncoached tester, beta testers, and each push, merge, tag and upload.

### Not in v1.0

Accessibility (first item after v1) · localization · iPad trackpad or mouse as the Mac pointer ·
QUIC lanes and per-frame streams · hosted CI · analytics or any crash-reporting service · Mac App
Store · shipping the command-line host · features locked behind a purchase.

## After v1.0

Parked as `post-v1` issues in Beads: accessibility, iPad pointer, lanes, media foundation, zoom
tuning, client decomposition, hosted CI. None starts without the owner.

## Constraints

- Apple Silicon only; macOS 26+ / iOS 26+. Swift 6.2 toolchain.
- The Mac must be logged in (no pre-login capture or remote unlock: a public-API limit).
- The iOS session is foreground-only; re-wake is a best-effort push through the user's own iCloud.
- No servers we host; remote use is the user's own overlay VPN. Static hosting is allowed.
- Permissive license: clean-room only.
</content>

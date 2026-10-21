# Current State

> Loop state only (≤20 lines). Rationale → `decisions.md`; details → `phases/v1-release-finish-spec.md`;
> backlog → `roadmap.md`.

Branch: `codex/v1-release-finish` · Gate 2 R3 sitting done 2026-10-20 (5/6).

## Plan — v1.0

- [x] Repo/bootstrap · Sitting 1 · notarized Developer-ID host · doc truth pass
- [x] Gate 0 preflight — SwiftPM 734 · Mac build + 24 · iOS sim 96 (green on Xcode 27.1, 2026-10-20)
- [x] Gate 1 CloudKit Production schema (`portview-lb9`)
- [ ] Gate 2 feature sweep — R3 (Xcode 27.1) 5 pass; audio FAIL (clicks ~2 s): fix landed, soak pending
- [ ] Gate 3 production re-wake (`portview-uma`)
- [ ] Gate 4 `wyi`: menu bar/settings/privacy defaults/iOS walkthrough
- [ ] Gate 5 archive validation/install-channel decision/tag handoff

## Blockers / open questions

- Audio click fix (continuous playout scheduling) is committed and test-green, but NOT device-verified.
  Next: device soak (Quality HUD audio line), then re-stage R4 and re-run all six Gate 2 rows.
- App Store: choose iPhone-only/universal orientations + zip/DMG; add `portview://`; Validate App later.

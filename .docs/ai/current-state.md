# Current State

> Loop state only (≤20 lines). Rationale → `decisions.md`; details → `phases/v1-release-finish-spec.md`.

Branch: `codex/v1-release-finish` · Gate 2 R2 staged on Roshar.

## Plan — v1.0

- [x] Repo/bootstrap · Sitting 1 · notarized Developer-ID host · doc truth pass
- [x] Gate 0 preflight — SwiftPM 734 · Mac build + 24 tests · iOS simulator 96 tests
- [x] Gate 1 CloudKit Production schema (`portview-lb9`)
- [?] Gate 2 R2 feature sweep — 6 pending in hdeck `20260819-gate2-product-test-r2`
- [ ] Gate 3 production re-wake (`portview-uma`)
- [ ] Gate 4 `wyi`: menu bar/settings/privacy defaults/iOS walkthrough
- [ ] Gate 5 archive validation/install-channel decision/tag handoff

## Blockers / open questions

- Human: run/approve all six R2 rows; any fail or NOT RUN keeps Gate 2 open.
- App Store: choose iPhone-only/universal orientations + zip/DMG; add `portview://`; Validate App later.

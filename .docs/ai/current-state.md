# Current State

> Loop state only (≤20 lines). Rationale → `decisions.md`; details → `phases/v1-release-finish-spec.md`.

Branch: `codex/v1-release-finish`, clean before handoff update.

## Plan — v1.0

- [x] Repo/bootstrap · Sitting 1 · notarized Developer-ID host · doc truth pass
- [x] Gate 0 preflight — SwiftPM 734 · Mac build + 24 tests · iOS simulator 90 tests
- [x] Gate 1 CloudKit Production schema (`portview-lb9`)
- [?] Gate 2 feature sweep — 1 pass · 1 fail · 4 pending in hdeck `20260811-gate2-product-test`
- [ ] Gate 3 production re-wake (`portview-uma`)
- [ ] Gate 4 `wyi`: menu bar/settings/privacy defaults/iOS walkthrough
- [ ] Gate 5 archive validation/install-channel decision/tag handoff

## Blockers / open questions

- Open: zip vs DMG before tagging; MenuBarExtra modals die on resign-key, so use inline rows.

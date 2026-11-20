# Current State

> Loop state only (≤20 lines). Rationale → `decisions.md`; details → `phases/v1-release-finish-spec.md`;
> backlog → `roadmap.md`.

Branch: `codex/v1-release-finish` · Gate 4 code complete 2026-11-19 (`3bd89b1..13aa150`).

## Plan — v1.0

- [x] Repo/bootstrap · Sitting 1 · notarized Developer-ID host · doc truth pass
- [x] Gate 0 preflight — SwiftPM 734 · Mac build + 24 · iOS sim 96 (green on Xcode 27.1, 2026-10-20)
- [x] Gate 1 CloudKit Production schema (`portview-lb9`)
- [ ] Gate 2 feature sweep — R3 5 pass; audio FAIL: fix landed, soak pending. R4: enable clipboard+files first
- [ ] Gate 3 production re-wake (`portview-uma`)
- [ ] Gate 4 `wyi` — code + reviews done; `make preflight` green @13aa150 (SwiftPM 812 · host 42 · iOS 126);
      17 named human checks PENDING → `phases/v1-release-finish-report.md`
- [ ] Gate 5 archive validation/install-channel decision/tag handoff

## Blockers / open questions

- Gate 4 + Gate 2 R4 + Gate 3 all need a hardware sitting (Mac at /Applications + iPhone).
- App Store: choose iPhone-only/universal orientations + zip/DMG; Validate App later.

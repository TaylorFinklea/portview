# Current State

> Loop state only (≤20 lines, per AGENTS.md). Rationale → `decisions.md`. Backlog → `bd ready`.
> The pre-2026-07-27 session journal was pruned; it remains in git history.

Branch: `main`, clean. 6 commits ahead of `origin/main` — **not pushed** (user reviews + pushes).

## Plan — v1.0 (rationale: `decisions.md` 2026-07-27)

- [x] `.gitignore` covers `ai-scratch/`, `.beads/`, `.pi-subagents/` — Verify: `git check-ignore -v`
- [x] Fresh clone buildable (`make bootstrap`) — Verify: clean clone → `make bootstrap` → `make build-host`
- [x] Break-glass pairing reset (store + menu bar) — Verify: `make preflight`
- [x] GUI runs `.required`; QR governed by the pairing window — Verify: `make preflight`
- [ ] **Sitting 1 (device)**: `.required` first-enrollment happy path → QR + SAS first-install →
      destructive LAST (revoke, last-device lockout, reset). Beads `portview-35d`, `portview-myt`.
- [ ] Sitting 2 feature sweep `portview-2u9` · Sitting 3 re-wake `portview-uma`
- [ ] Release eng: hardened runtime + Developer ID + notarize; `LSUIElement`; iOS archive
      validation; camera-denial handling; `CFBundleURLTypes`; CHANGELOG + tag
- [ ] Doc truth pass (`SECURITY.md` is publicly wrong) + `decisions.md` journal pruning

## Blockers / open questions

- `portview-qhl` — scope lost in the beads DB migration; user must restate or close.
- `portview-wyi` — settings/first-run needs user product decisions.
- Re-wake stays in v1.0 ⇒ the host iCloud entitlement (`PORTVIEW_HOST_ENTITLEMENTS`, empty today)
  is on the notarization critical path. A release build today ships re-wake silently disabled.
- **Nothing in the four checked items above has run on hardware.**

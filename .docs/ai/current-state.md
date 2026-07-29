# Current State

> Loop state only (≤20 lines, per AGENTS.md). Rationale → `decisions.md`. Backlog → `bd ready`.
> The pre-2026-07-27 session journal was pruned; it remains in git history.

Branch: `main`, clean. 11 commits ahead of `origin/main` — **not pushed** (user reviews + pushes).

## Plan — v1.0 (rationale: `decisions.md` 2026-07-27, 2026-07-28)

- [x] Repo ignores · fresh-clone `make bootstrap` · break-glass reset · GUI on `.required` · QR gated
- [x] `portview-wyi` answered → 4 impl beads · `portview-qhl` closed (range drift split out)
- [x] **Sitting 1 PASSED 2026-07-28** (Roshar + Mandalore). `.required` enrollment ceremony works on
      hardware — the epic's first device minutes. Revoke, live-session kill, last-device lockout,
      QR gating and the reset all confirmed. 3 defects found + fixed + re-verified: `7ty`, `l27`.
- [ ] Sitting 2 feature sweep `portview-2u9` — clipboard/audio/files/multi-monitor still unproven
- [ ] Sitting 3 re-wake `portview-uma`
- [ ] `wyi` implementation: menu-bar-is-the-app · host settings · clipboard+files opt-in · iOS walkthrough
- [ ] Release eng: hardened runtime + Developer ID + notarize; iOS archive validation;
      camera-denial handling; `CFBundleURLTypes`; CHANGELOG + tag
- [ ] Doc truth pass (`SECURITY.md` is publicly wrong) + `decisions.md` journal pruning

## Blockers / open questions

- Re-wake stays in v1.0 ⇒ host iCloud entitlement (`PORTVIEW_HOST_ENTITLEMENTS`, empty) is on the
  notarization critical path. A release build today ships re-wake silently disabled.
- Landmine: SwiftUI modals (`.confirmationDialog`/alert) do NOT work from the `.window`-style
  MenuBarExtra popover — it closes on resign-key. Use inline rows. LAContext from it is fine.

# Current State

> Loop state only (≤20 lines, per AGENTS.md). Rationale → `decisions.md`. Backlog → `bd ready`.
> The pre-2026-07-27 session journal was pruned; it remains in git history.

Branch: `main`, clean. 9 commits ahead of `origin/main` — **not pushed** (user reviews + pushes).

## Plan — v1.0 (rationale: `decisions.md` 2026-07-27, 2026-07-28)

- [x] Repo ignores · fresh-clone `make bootstrap` · break-glass reset · GUI on `.required` · QR gated
- [x] `portview-wyi` answered → 4 impl beads · `portview-qhl` closed (range drift split out)
- [~] **Sitting 1 IN PROGRESS** (`portview-35d`, `portview-myt`; Roshar + Mandalore, fresh builds installed)
  - [x] Leg A — `.required` enrollment ceremony works on hardware. The big unknown is retired.
  - [x] Device-found: menu-bar `.confirmationDialog` unclickable → inline confirms (`e63d7ce`)
  - [ ] Re-test revoke + last-device banner → THEN QR-with-window-closed (needs Roshar unenrolled) → reset
- [ ] Sitting 2 feature sweep `portview-2u9` · Sitting 3 re-wake `portview-uma`
- [ ] Release eng: hardened runtime + Developer ID + notarize; `LSUIElement`; iOS archive
      validation; camera-denial handling; `CFBundleURLTypes`; CHANGELOG + tag
- [ ] Doc truth pass (`SECURITY.md` is publicly wrong) + `decisions.md` journal pruning

## Blockers / open questions

- Re-wake stays in v1.0 ⇒ host iCloud entitlement (`PORTVIEW_HOST_ENTITLEMENTS`, empty) is on the
  notarization critical path. A release build today ships re-wake silently disabled.
- Leg-B caveat: an ENROLLED device re-dialing a pinned host needs no pairing window — correct, and
  the `7hn` fix only governs UNKNOWN keys. Only testable after a revoke.

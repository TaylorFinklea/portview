# Current State

> Loop state only (≤20 lines, per AGENTS.md). Rationale → `decisions.md`. Backlog → `bd ready`.
> The pre-2026-07-27 session journal was pruned; it remains in git history.

Branch: `main`, clean. 3 commits ahead of `origin/main`.

## Plan — v1.0 (rationale: `decisions.md` 2026-07-27, 2026-07-28)

- [x] Repo ignores · fresh-clone `make bootstrap` · break-glass reset · GUI on `.required` · QR gated
- [x] **Sitting 1 PASSED** — `.required` enrollment, revoke + live-session kill, lockout, reset all
      device-confirmed. 3 defects found/fixed/re-verified (`7ty`, `l27`).
- [x] **Notarized Developer-ID host** — `make release` end-to-end; quarantined-zip test gives
      `spctl: accepted, source=Notarized Developer ID` + stapled (passes Gatekeeper offline).
- [ ] **Deploy CloudKit schema to PRODUCTION** (`portview-lb9`, P1) — release carries
      `icloud-container-environment=Production`; schema does NOT auto-promote and beacon writes
      fail SOFT, so skipping it ships a host that looks healthy and wakes nobody.
- [ ] Sitting 2 feature sweep `portview-2u9` — clipboard/audio/files/multi-monitor still unproven
- [ ] Sitting 3 re-wake `portview-uma` — only meaningful on a PRODUCTION-signed build, so after ↑
- [ ] `wyi` impl: menu-bar-is-the-app · host settings · clipboard+files opt-in · iOS walkthrough
- [x] Doc truth pass — SECURITY.md rewritten (mutual auth + enrollment + revoke + reset + iCloud
      in the trust model, known limitations stated); README/apps-README/AGENTS.md honest;
      CHANGELOG + CONTRIBUTING created; absolute paths stripped from public specs
- [ ] iOS archive/upload validation · camera-denial · `CFBundleURLTypes` · tag

## Blockers / open questions

- No install artifact beyond the zip (no .dmg/installer); the ditto-to-/Applications path is still
  informal. Zip is a legitimate v1.0 channel — decide before the tag.
- Landmine: SwiftUI modals (`.confirmationDialog`/alert) do NOT work from the `.window`-style
  MenuBarExtra popover — it closes on resign-key. Use inline rows. LAContext from it is fine.

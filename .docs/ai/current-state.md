# Current State

> Short and current. Outcomes → `roadmap.md`; the v1.0 plan →
> `docs/superpowers/specs/2026-11-21-v1-production-roadmap-design.md`; rulings → `decisions.md`;
> task state → Beads. Run `bd --sandbox where`, then `bd --sandbox prime`, from either checkout:
> both resolve to the one store at the main checkout's `.beads`.

Branch: `codex/v1-release-finish` (pushed to origin as a backup). `main` is stale; do not read
status from it. Work happens in the worktree `.worktrees/v1-release-finish`.

## Where things are (2026-11-25)

- The v1.0 production roadmap is approved by the owner. Phase 0 (handoff) is done.
- Gate 4 code is complete and green (`make preflight`: SwiftPM 812 · host 42 · iOS 126). Its 17
  device checks, Gate 2's re-run and Gate 3 are folded into the roadmap's Phase 3 session.
- Nothing from Phase 2 has started. No release, tag, TestFlight build or site exists.

## Next for the executing lead

1. Done 2026-11-27 (`portview-p1-stage`): the risk-check checklist and staging steps are in
   `phases/v1-risk-check-checklist.md`. Staging runs only with the owner present. After the
   sitting, copy the owner's results into that file as "owner reported" and file each failure
   under `portview-w10`.
2. In parallel with the owner's sitting, start what needs nothing from the owner: `portview-w1`,
   `portview-w4-spike`, `portview-w5`, `portview-w7`, `portview-w8`, `portview-w9`, `portview-w11`.
   `portview-w3-probe` needs the owner and their iPad with a hardware keyboard (it runs with
   check C5); prepare the probe build so it is ready for that sitting.
3. Each workstream: step-level plan first, `gpt-6.2-sol` plan review where the issue says so,
   Sonnet implementers, `gpt-6.1-terra` and a fresh Sonnet diff review before it is reported done.

## Never without the owner

- No push, merge, tag, release, upload, publish, account or app-record creation, or change to repo
  or DNS settings without the owner's approval for that specific action.
- No install or launch on the owner's devices, and no notarization run, without the owner.
- A named device check is never recorded as passed by an agent.
- No feature is cut and no acceptance point changed by an agent; after two failed fix attempts
  the owner decides. Nothing in the frozen auth and pairing design is reopened.
- Issues labeled `owner` are the owner's to do or decide; `post-v1` issues are deferred and are
  not started. The `portview-v1` and `portview-w10` epics are containers, not tasks.

## Waiting on the owner

- The Phase 1 sitting (`portview-p1`), then approval to land the branch on `main`
  (`portview-own-land`).
- Decisions `portview-d1` (hostname), `portview-d2` (support address), `portview-d4` (tip amounts).
</content>

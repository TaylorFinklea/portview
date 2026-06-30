# screenshare — Agent Instructions

Shared agent rules live in `~/AGENTS.md` (chezmoi-managed; applies to every repo). This file adds only repo-specific guidance.

## Task tracking — beads (`bd`)

This repo's backlog / "what to work on next" is tracked in **beads** (`bd`), a dependency-aware issue tracker — not a markdown TODO. Local stealth install: `.beads/` is git-excluded; nothing is committed.

Agent loop (harness-agnostic — `bd` is just a CLI):
- `bd ready` — priority-sorted, dependency-aware queue of unblocked work (`--json` for scripting; `bd ready --claim --json` claims the top item atomically).
- `bd show <id>` — detail before starting.
- `bd update <id> --claim` — set in_progress + assignee atomically.
- Run the repo's build/test, then `bd close <id> --reason "…"`.
- `bd create "Title" -t task -p 2 -d "…"` — file new or mid-task-discovered work; `bd dep add <a> <b>` records `<a>` is blocked-by `<b>`.

beads owns ONLY the backlog/ready-queue. Rationale/ADRs → `.docs/ai/decisions.md`, multi-session design → `.docs/ai/phases/*` (markdown prose; create as the project grows). Part of a cross-repo beads pilot (2026-06-30); see chezmoi-config `.docs/ai/phases/beads-pilot-spec.md`.

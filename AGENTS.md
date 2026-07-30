# portview — Agent Instructions

Repo-specific guidance for AI coding agents. (The maintainer's cross-repo agent rules live
outside this repository; contributors and their tools only need what's below plus
`CONTRIBUTING.md`.)

## Task tracking — beads (`bd`)

The maintainer's backlog / "what to work on next" is tracked in **beads** (`bd`), a
dependency-aware issue tracker — not a markdown TODO. It is a local stealth install: `.beads/`
is gitignored, so clones won't have it; if `bd` isn't available, treat `.docs/ai/roadmap.md` +
`.docs/ai/current-state.md` as the work queue.

Agent loop (harness-agnostic — `bd` is just a CLI):
- `bd ready` — priority-sorted, dependency-aware queue of unblocked work (`--json` for scripting; `bd ready --claim --json` claims the top item atomically).
- `bd show <id>` — detail before starting.
- `bd update <id> --claim` — set in_progress + assignee atomically.
- Run the repo's build/test (`make preflight`; fresh clone: `make bootstrap` first), then `bd close <id> --reason "…"`.
- `bd create "Title" -t task -p 2 -d "…"` — file new or mid-task-discovered work; `bd dep add <a> <b>` records `<a>` is blocked-by `<b>`.

beads owns ONLY the backlog/ready-queue. Rationale/ADRs → `.docs/ai/decisions.md`,
multi-session design → `.docs/ai/phases/*` (markdown prose; create as the project grows).

## Repo landmines

- Tests must NEVER touch live system surfaces (CGEvent, pasteboard, audible audio, IOPM,
  keychain — except the deliberate `KeychainIdentityStoreTests`). Every live surface has an
  injectable seam at the effect boundary; use it.
- Run `swift package clean` before trusting a RED **or** a GREEN after changing a type's
  stored properties — SPM serves stale test objects.
- `make … | tail` reports the pipeline's exit status (tail's), not make's.
- SwiftUI modals (`.confirmationDialog`/`.alert`) do not work from the `.window`-style
  `MenuBarExtra` popover — it closes on resign-key and the modal dies with it. Use inline
  confirm rows. `LAContext` from the popover is fine.
- Host device-test installs go to `/Applications/PortviewHost.app` (never run from `/tmp`) —
  TCC Screen Recording grants are per-path.
- `ProtocolVersion.current` stays 1 on purpose; QUIC lane splitting is landed but dormant.

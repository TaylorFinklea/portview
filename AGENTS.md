# portview — Agent Instructions

Repo-specific guidance for AI coding agents. (The maintainer's cross-repo agent rules live
outside this repository; contributors and their tools only need what's below plus
`CONTRIBUTING.md`.)

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

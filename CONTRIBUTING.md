# Contributing to Portview

Thanks for your interest! Portview is early and moving fast; small, focused PRs work best.

## Building

- **Requirements:** Xcode 26 on macOS 26, Apple Silicon, plus [XcodeGen](https://github.com/yonaskolb/XcodeGen)
  (`brew install xcodegen`) — both apps' `.xcodeproj` are generated from `project.yml` and not tracked.
- **Fresh clone:**

  ```bash
  make bootstrap   # verifies xcodegen, generates both projects, arms the pre-push gate
  make preflight   # swift test + macOS host build + host tests + iOS simulator tests
  ```

- **Your own signing team:** don't edit tracked files — create `apps/Portview.local.xcconfig`
  (gitignored) per `apps/README.md`. Caveat: the CloudKit re-wake container id is the
  maintainer's and can't be provisioned by other teams; dev builds skip it automatically
  (the feature fails soft), so everything else builds and runs without it.

## Ground rules

- `make preflight` must pass before a PR. There is deliberately no hosted CI — the suite
  needs a real Keychain, loopback QUIC listeners, and a hardware HEVC encoder — so the
  pre-push hook (installed by `make bootstrap`) is the gate.
- **Tests must never touch live system surfaces** — no real CGEvent posting, pasteboard
  writes, audible audio, or IOPM assertions. Every live surface has an injectable seam at
  the effect boundary; tests inject fakes there. (The one deliberate exception is
  `KeychainIdentityStoreTests`, which exercises real `SecItem` calls.)
- Prefer TDD for behavior changes: a failing test first, especially for anything touching
  pairing, revocation, or the wire protocol.
- Wire changes must follow the bump rules documented in
  `Sources/PortviewProtocol/ProtocolVersion.swift` — `ProtocolVersion.current` stays 1
  until the dormant QUIC lane split is validated on device.
- Keep the license clean: Apache-2.0, no code derived from GPL screen-sharing projects.

## Security issues

Please don't open public issues for suspected vulnerabilities — see [`SECURITY.md`](SECURITY.md)
for private reporting.

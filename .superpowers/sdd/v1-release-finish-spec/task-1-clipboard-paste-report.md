# Task 1 — Gate 2 iPhone to Mac paste-control fix

- Status: `DONE_WITH_CONCERNS`
- Root cause addressed: the live HUD read `UIPasteboard.general.string` from a custom button, so the reverse-clipboard path depended on a programmatic pasteboard read rather than SwiftUI's user-intent paste control. The HUD now uses `PasteButton(payloadType: String.self)` and forwards each delivered string through `SessionViewModel.sendClipboardText(_:)`.
- Files changed:
  - `apps/PortviewClient/Sources/LiveHUDView.swift`
  - `apps/PortviewClient/Sources/SessionViewModel.swift`
  - `apps/PortviewClient/Tests/ClipboardSendTests.swift`
  - `apps/PortviewClient/Tests/OutboundInputPumpTests.swift`
- Red evidence: after `make generate`, the focused iOS test command failed to compile with the expected missing `SessionViewModel.outboundMessageSink` and `SessionViewModel.sendClipboardText` members.
- Green evidence:
  - `make generate` — passed.
  - Focused `xcodebuild test` on iPhone 17 Simulator, covering `ClipboardSendTests` and `OutboundInputPumpTests` — 6 tests passed, 0 failed (xcresult summary).
  - `git diff --check` — passed.
- Self-review: the new tests use only an injected outbound sink and an `OutboundInputPump` sink; no test reads or writes `UIPasteboard`, CGEvent, audio, keychain, or a physical device. Empty and over-cap strings are dropped without trimming or truncation. The existing connection-bound FIFO pump remains the production send path, and the parent reconnect disablement still wraps the paste control. `ProtocolVersion.current` and host/transport code are unchanged.
- Commit: `dd7cfea`
- Concerns: the controller still needs the physical Gate 2 reverse-clipboard retest with a new unique marker and exact Mac-side equality; this change does not claim that hardware gate.

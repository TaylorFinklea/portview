# macOS Host App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a signed macOS `PortviewHost.app` target so Screen Recording and Accessibility permissions attach to Portview instead of the terminal used by `swift run`.

**Architecture:** Extract the existing host runtime from the SwiftPM executable into a macOS-only `PortviewHostCore` library. Keep `portview-host` as a CLI wrapper, and add an XcodeGen-managed SwiftUI `PortviewHost` macOS app that starts the same runner in-process and displays permission and pairing state.

**Tech Stack:** Swift 6.2 SwiftPM, XcodeGen, macOS 26, SwiftUI/AppKit, ScreenCaptureKit, Network.framework QUIC, VideoToolbox.

---

## Files

- Modify `Package.swift`: add `PortviewHostCore` library product/target and move host implementation files into it; keep `portview-host` executable as wrapper.
- Create `Sources/PortviewHostCore/HostRunner.swift`: reusable runner, status/events, permission helpers, host startup, serving, and video pump logic moved from `PortviewHostApp.swift`.
- Move existing helper files from `Sources/portview-host/` to `Sources/PortviewHostCore/` where they are used by both CLI and app: `CaptureEngine.swift`, `CaptureSizing.swift`, `ClipboardSync.swift`, `FileReceiver.swift`, `InputInjector.swift`, `NetworkInterface.swift`, `QualityStatsAccumulator.swift`, `TerminalQR.swift`.
- Replace `Sources/portview-host/PortviewHostApp.swift` with a thin CLI wrapper around `HostRunner`.
- Modify `Tests/PortviewHostTests/CaptureSizingTests.swift`: import `PortviewHostCore` instead of depending on the executable target.
- Add focused tests in `Tests/PortviewHostTests/HostRunnerTests.swift` for pure runner state/formatting behavior.
- Create `apps/PortviewHost/project.yml`: macOS app target with bundle ID `dev.finklea.portview.host`, package dependencies, and automatic signing.
- Create `apps/PortviewHost/Sources/PortviewHostApp.swift`, `ContentView.swift`, and `HostAppModel.swift`: SwiftUI app, status window, runner task management.
- Update `apps/README.md`, `.docs/ai/roadmap.md`, and `.docs/ai/current-state.md` with the new run path and verification status.

## Tasks

### Task 1: Extract Host Core Behind Tests

- [x] Write `Tests/PortviewHostTests/HostRunnerTests.swift` against wished-for pure APIs: host-ready display text includes address/port/pin/pairing URL; permission guidance says app identity for app mode and terminal identity for CLI mode.
- [x] Run `swift test --package-path /Users/tfinklea/git/screenshare --filter HostRunnerTests` and confirm it fails because `PortviewHostCore`/runner APIs do not exist yet.
- [x] Add `PortviewHostCore` product/target in `Package.swift` and move reusable host files into `Sources/PortviewHostCore/`.
- [x] Implement `HostRunner`, host status/event structs, and CLI/app permission guidance helpers by moving existing `PortviewHostApp` logic rather than rewriting capture/session behavior.
- [x] Replace `Sources/portview-host/PortviewHostApp.swift` with a CLI entry point that invokes `HostRunner.runForCLI()` and prints events.
- [x] Run the focused host tests and `swift build --package-path /Users/tfinklea/git/screenshare --product portview-host`.

### Task 2: Add macOS Host App Target

- [x] Create `apps/PortviewHost/project.yml` using the repo's XcodeGen conventions and automatic signing team `K7CBQW6MPG`.
- [x] Create `apps/PortviewHost/Sources/HostAppModel.swift` as `@MainActor ObservableObject`; it owns a runner task, starts/stops hosting, and publishes screen-recording/accessibility/ready/error state from runner callbacks.
- [x] Create `apps/PortviewHost/Sources/ContentView.swift` with a small SwiftUI status window: permission rows, host-ready details, copy pairing URL button, and open-settings buttons.
- [x] Create `apps/PortviewHost/Sources/PortviewHostApp.swift` with `WindowGroup`, default sizing, and app shutdown cleanup.
- [x] Run `xcodegen generate` in `apps/PortviewHost` and build with `xcodebuild build -project apps/PortviewHost/PortviewHost.xcodeproj -scheme PortviewHost -destination 'platform=macOS'`.

### Task 3: Verify End-To-End Build Paths And Docs

- [x] Run `swift test --package-path /Users/tfinklea/git/screenshare`.
- [x] Run `swift build --package-path /Users/tfinklea/git/screenshare --product portview-host`.
- [x] Run the macOS app build command from Task 2 again after fixes.
- [x] Update `apps/README.md` to make `PortviewHost.app` the primary Mac host run path and keep `swift run portview-host` as a developer fallback.
- [x] Update `.docs/ai/roadmap.md` and `.docs/ai/current-state.md` with the app target status and remaining manual TCC/device retest.
- [x] Commit the implementation.

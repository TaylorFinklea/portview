# Settings, Privacy Defaults, and First-Run Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the menu bar the complete Mac host experience, add persistent host preferences,
default clipboard/file access off at real effect boundaries, and give the iOS client a truthful
first-run and camera/URL recovery flow.

**Architecture:** Keep persisted values and decision logic pure and injectable; keep AppKit,
SMAppService, AVFoundation, and SwiftUI at app edges. A shared lock-guarded `HostAccessPolicy`
enforces clipboard and file preferences at the exact host effect boundaries, including live
sessions. The existing `PairingPayload` parser remains the one entry point for QR and URL pairing.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit, ServiceManagement/`SMAppService`, AVFoundation,
UserDefaults, XcodeGen, Swift Testing for package tests, XCTest for app logic tests.

## Global constraints

- Follow `.docs/ai/decisions.md` 2026-07-28 exactly: menu bar is the app; settings are launch at
  login, preferred port, default display; clipboard/files opt-in; full iOS walkthrough.
- `MenuBarExtra(.window)` cannot present reliable `.alert` or `.confirmationDialog`; every Mac
  permission, setting, and confirmation flow must stay inline.
- Disabling clipboard/file access must affect already-connected sessions before the toggle returns.
- Clipboard disabled means no Mac pasteboard reads, writes, or outbound clipboard sends.
- File transfer disabled means no inbound file creation/write/finalize/delete and no outbound file
  offer/chunk sends. Hiding buttons is secondary UX, never the security boundary.
- Screen capture and input remain enabled by default for authenticated sessions.
- Tests never touch live pasteboard, file Downloads, SMAppService, TCC, or camera hardware.
- Run Xcode commands with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` on this machine.

---

### Task 1: Pure host preference storage and launch-at-login seam

**Files:**
- Create: `apps/PortviewHost/Sources/HostPreferences.swift`
- Create: `apps/PortviewHost/Sources/LaunchAtLoginController.swift`
- Create: `apps/PortviewHost/Tests/HostPreferencesTests.swift`
- Modify: `apps/PortviewHost/project.yml`

**Interfaces:**
- Produces: `HostPreferences: Codable, Equatable` with `preferredPort: UInt16?`,
  `preferredDisplayID: UInt32?`, `clipboardEnabled: Bool`, and `fileTransferEnabled: Bool`.
- Produces: `HostPreferences.defaults`, whose clipboard/file values are both `false`.
- Produces: `HostPreferencesStore`, initialized with injectable `UserDefaults`, that publishes and
  persists one `HostPreferences` value.
- Produces: `LaunchAtLoginControlling` (`isEnabled`, `setEnabled(_:) throws`) and the production
  `SMAppService.mainApp` adapter. Do not duplicate launch-at-login state in UserDefaults.

- [ ] **Step 1: Add the pure failing preference tests**

```swift
func testPrivacySensitiveDefaultsAreOff() {
    XCTAssertFalse(HostPreferences.defaults.clipboardEnabled)
    XCTAssertFalse(HostPreferences.defaults.fileTransferEnabled)
}

func testRoundTripPreservesPortAndDisplay() {
    let value = HostPreferences(
        preferredPort: 7443, preferredDisplayID: 42,
        clipboardEnabled: true, fileTransferEnabled: false)
    XCTAssertEqual(try JSONDecoder().decode(HostPreferences.self,
        from: JSONEncoder().encode(value)), value)
}
```

- [ ] **Step 2: Register the new pure source files in the logic-test target**

Add `Sources/HostPreferences.swift` and `Sources/LaunchAtLoginController.swift` beside
`Sources/DeviceRowStatus.swift` under `PortviewHostTests.sources`. The controller file must keep the
`SMAppService` adapter behind the protocol so tests use a fake and never register a login item.

- [ ] **Step 3: Run the tests and confirm RED**

Run:
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make generate`

Then:
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project apps/PortviewHost/PortviewHost.xcodeproj -scheme PortviewHost -destination 'platform=macOS' -only-testing:PortviewHostTests/HostPreferencesTests`

Expected: compile failure because the types do not exist.

- [ ] **Step 4: Implement the minimal store and controller seam**

Use one encoded defaults key, decode failure → `HostPreferences.defaults`, and write-through on
changes. Map `SMAppService.mainApp.status == .enabled` to `isEnabled`; `setEnabled(true)` calls
`register()`, false calls `unregister()`.

- [ ] **Step 5: Add fake-controller tests**

Assert the settings-facing coordinator reports the fake's current value, calls the requested
transition once, and surfaces an error without lying that the state changed.

- [ ] **Step 6: Run GREEN and commit**

Run the focused xcodebuild command above, then:

```bash
git add apps/PortviewHost/project.yml apps/PortviewHost/Sources/HostPreferences.swift \
  apps/PortviewHost/Sources/LaunchAtLoginController.swift \
  apps/PortviewHost/Tests/HostPreferencesTests.swift
git commit -m "feat: add persistent host preferences"
```

### Task 2: Thread preferred port and display through the host runtime

**Files:**
- Create: `Sources/PortviewHostCore/HostRuntimePreferences.swift`
- Create: `Tests/PortviewHostTests/HostRuntimePreferencesTests.swift`
- Modify: `Sources/PortviewHostCore/HostRunner.swift`
- Modify: `apps/PortviewHost/Sources/HostAppModel.swift`

**Interfaces:**
- Consumes: `HostPreferencesStore` from Task 1.
- Produces: immutable `HostRuntimePreferences(preferredPort: UInt16?, preferredDisplayID: UInt32?)`.
- Produces: pure selection helpers used by `HostRunner` to choose an explicit preferred port before
  the identity's last bound port, and a preferred display when it is currently available.

- [ ] **Step 1: Write failing pure selection tests**

Cover these exact cases:

```swift
#expect(HostRuntimePreferences(preferredPort: 7443, preferredDisplayID: nil)
    .listenerPort(lastBoundPort: 9000) == 7443)
#expect(HostRuntimePreferences(preferredPort: nil, preferredDisplayID: nil)
    .listenerPort(lastBoundPort: 9000) == 9000)
#expect(HostRuntimePreferences(preferredPort: nil, preferredDisplayID: 42)
    .initialDisplayID(available: [7, 42]) == 42)
#expect(HostRuntimePreferences(preferredPort: nil, preferredDisplayID: 99)
    .initialDisplayID(available: [7, 42]) == 7)
```

- [ ] **Step 2: Run RED**

Run: `swift test --filter HostRuntimePreferencesTests`

Expected: compile failure because `HostRuntimePreferences` does not exist.

- [ ] **Step 3: Implement the pure value and pass it through `HostRunner.events`/`run`**

Preserve source compatibility with a default value. The GUI passes a snapshot from
`HostPreferencesStore`; the CLI receives the safe default. At listener startup use explicit
preference → last-bound identity port → OS-assigned fallback, in that order. Do not overwrite the
explicit user preference when the port is temporarily unavailable.

- [ ] **Step 4: Apply default-display selection at the existing first-display seam**

Keep `DisplayRegistry` as the live list. Resolve the preferred ID only when choosing the initial
session display; fall back to the current first display if it disappeared. Display switching and
refresh behavior stay unchanged.

- [ ] **Step 5: Run focused and full package tests**

Run:

```bash
swift test --filter HostRuntimePreferencesTests
swift test --filter StartListenerTests
swift test --filter DisplayRefreshTests
```

- [ ] **Step 6: Commit**

```bash
git add Sources/PortviewHostCore/HostRuntimePreferences.swift \
  Sources/PortviewHostCore/HostRunner.swift apps/PortviewHost/Sources/HostAppModel.swift \
  Tests/PortviewHostTests/HostRuntimePreferencesTests.swift
git commit -m "feat: honor host port and display preferences"
```

### Task 3: Make permissions and settings complete inside the menu-bar app

**Files:**
- Modify: `apps/PortviewHost/Sources/MenuBarHostView.swift`
- Modify: `apps/PortviewHost/Sources/HostAppModel.swift`
- Modify: `apps/PortviewHost/Sources/PortviewHostApp.swift`
- Modify: `apps/PortviewHost/project.yml`
- Delete after parity is proven: `apps/PortviewHost/Sources/ContentView.swift`
- Create: `apps/PortviewHost/Tests/MenuBarSettingsRoutingTests.swift`

**Interfaces:**
- Consumes: `HostPreferencesStore` and `LaunchAtLoginControlling` from Task 1.
- Produces: inline popover sections for permissions and settings.
- Produces: `HostAppModel` methods that validate/store preferred port and display and report
  launch-at-login errors without dismissing the popover.

- [ ] **Step 1: Inventory every main-window-only action before deletion**

Use `ContentView.swift` as the source checklist: Screen Recording status/open-settings, Accessibility
status/open-settings, re-check/relaunch copy, failure details, connected-device file action, and any
activity/status copy not already present in `MenuBarHostView`. Mark each as moved or intentionally
retired in the task commit message; do not delete the window first.

- [ ] **Step 2: Write failing routing tests**

Test pure validation/routing values, not SwiftUI rendering:

- port accepts `1...65535`, blank means automatic, invalid text does not persist;
- unavailable remembered display renders as automatic/current instead of a stale selection;
- launch-at-login failure leaves the prior displayed state and provides an inline error;
- clipboard/file defaults appear off.

- [ ] **Step 3: Add the inline permission section**

Move the real `PermissionsOnboarding`-derived status and the existing
`openScreenRecordingSettings`/`openAccessibilitySettings` actions into `MenuBarHostView`. Preserve
the Screen Recording relaunch caveat. Use inline rows only; no sheet, alert, or confirmation dialog.

- [ ] **Step 4: Add the inline settings disclosure**

Add launch at login, preferred port, default display, clipboard, and file transfer controls. Port and
default-display changes apply at the next host start and say so; do not silently disconnect active
sessions. Privacy toggles are live and are completed by Task 4's shared policy.

- [ ] **Step 5: Remove window-only navigation**

Remove `@Environment(\.openWindow)`, the **Open window** action, `mainWindowID`, and `WindowGroup`.
Add `LSUIElement: true` to the host Info properties in `project.yml`. Delete `ContentView.swift` only
after every item from Step 1 is reachable in the popover.

- [ ] **Step 6: Verify the app layer**

Run:

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project apps/PortviewHost/PortviewHost.xcodeproj -scheme PortviewHost -destination 'platform=macOS'`

Then build and launch with `./script/build_and_run.sh --verify`.

- [ ] **Step 7: Named human check**

The app has a menu-bar item and no Dock icon/window; Screen Recording and Accessibility recovery are
usable from the popover; settings persist across quit/relaunch; Quit exits and does not relaunch.

- [ ] **Step 8: Commit**

```bash
git add apps/PortviewHost
git commit -m "feat: make the menu bar the complete host app"
```

### Task 4: Enforce live clipboard and file opt-in at host effect boundaries

**Files:**
- Create: `Sources/PortviewHostCore/HostAccessPolicy.swift`
- Create: `Tests/PortviewHostTests/HostAccessPolicyTests.swift`
- Modify: `Sources/PortviewHostCore/HostRunner.swift`
- Modify: `Sources/PortviewHostCore/ClipboardSync.swift`
- Modify: `Sources/PortviewHostCore/FileReceiver.swift`
- Modify: `Sources/PortviewHostCore/HostControl.swift`
- Modify: `apps/PortviewHost/Sources/HostAppModel.swift`
- Modify: `apps/PortviewHost/Sources/MenuBarHostView.swift`
- Modify: `Tests/PortviewHostTests/ClipboardSyncTests.swift`
- Modify: `Tests/PortviewHostTests/FileReceiverTests.swift`
- Modify: `Tests/PortviewHostTests/HostControlRegistryTests.swift`

**Interfaces:**
- Produces: one process-wide, lock-guarded `HostAccessPolicy` with synchronous reads and updates for
  `clipboardEnabled` and `fileTransferEnabled`.
- Consumes: initial and changed values from `HostPreferencesStore`.
- `ClipboardSync`, `FileReceiver`, and `HostControl.sendFile` consume the same policy instance used
  by active sessions.

- [ ] **Step 1: Write RED policy tests**

```swift
@Test func secureDefaultsDenySensitiveEffects() {
    let policy = HostAccessPolicy()
    #expect(!policy.clipboardEnabled)
    #expect(!policy.fileTransferEnabled)
}

@Test func disablingIsVisibleSynchronously() {
    let policy = HostAccessPolicy(clipboardEnabled: true, fileTransferEnabled: true)
    policy.update(clipboardEnabled: false, fileTransferEnabled: false)
    #expect(!policy.clipboardEnabled)
    #expect(!policy.fileTransferEnabled)
}
```

- [ ] **Step 2: Extend effect tests before implementation**

Add tests proving:

- disabled clipboard polling never reads the fake pasteboard and never invokes its outbound sink;
- disabled remote clipboard never writes the fake pasteboard;
- toggling clipboard off after `start` stops later reads/sends;
- disabled file offer creates no file;
- toggling file off mid-transfer blocks subsequent write/finalize/delete effects;
- disabled `HostControl.sendFile` sends neither `.fileOffer` nor `.fileChunk`;
- enabling each policy restores the existing valid-capability behavior.

- [ ] **Step 3: Run RED**

Run:

```bash
swift test --filter HostAccessPolicyTests
swift test --filter ClipboardSyncTests
swift test --filter FileReceiverTests
```

- [ ] **Step 4: Implement the shared policy at the irreducible boundaries**

Do not wrap `SessionCapability.perform` inside itself. Extend each existing self-guarding effect
boundary with the policy check beside the capability check:

- `ClipboardSync.start`: check before pasteboard read and before outbound send;
- `ClipboardSync.applyRemote`: check inside the deferred MainActor mutation;
- `FileReceiver.offer/chunk/finalize/drop`: check inside the same critical section as the file effect;
- `HostControl.sendFile`: check before offer and again before every chunk so a live disable stops an
  in-progress outbound transfer.

- [ ] **Step 5: Wire one policy instance from the app model through every session**

`HostAppModel` owns the policy, initializes it from persisted preferences, and updates it
synchronously before the settings action returns. `HostRunner` passes that object to every
`ClipboardSync`/`FileReceiver`; `HostControl` receives the same object. UI disabling/hiding of file
actions may follow, but must not be the gate.

- [ ] **Step 6: Run the focused security regression set**

```bash
swift test --filter HostAccessPolicyTests
swift test --filter ClipboardSyncTests
swift test --filter FileReceiverTests
swift test --filter OutboundCapabilityGatingTests
swift test --filter HostControlRegistryTests
```

- [ ] **Step 7: Commit**

```bash
git add Sources/PortviewHostCore apps/PortviewHost/Sources \
  Tests/PortviewHostTests
git commit -m "feat: make clipboard and files host opt-in"
```

### Task 5: Replace the QR camera dead end with an explicit permission state

**Files:**
- Create: `apps/PortviewClient/Sources/CameraAccessModel.swift`
- Create: `apps/PortviewClient/Tests/CameraAccessModelTests.swift`
- Modify: `apps/PortviewClient/Sources/QRScannerView.swift`
- Modify: `apps/PortviewClient/Sources/PairView.swift`

**Interfaces:**
- Produces: `CameraAccessState` with `.notDetermined`, `.requesting`, `.authorized`, `.denied`, and
  `.unavailable`.
- Produces: an injectable authorization client that maps AVFoundation status, requests once, and
  opens `UIApplication.openSettingsURLString` only from an explicit user action.
- `PairView` always retains manual pairing and close actions, regardless of camera state.

- [ ] **Step 1: Write failing state-machine tests**

Cover authorized → scanner, notDetermined → one request → resolved state, denied → recovery copy,
request failure → denied/unavailable, and no camera device → unavailable. Tests use closures/fakes;
never instantiate `AVCaptureSession`.

- [ ] **Step 2: Run RED**

Run:

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project apps/PortviewClient/PortviewClient.xcodeproj -scheme PortviewClient -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:PortviewClientTests/CameraAccessModelTests`

- [ ] **Step 3: Implement permission-driven scanner startup**

`QRScannerView` starts capture only for `.authorized`. `PairView` shows:

- requesting: progress plus manual pairing;
- denied: “Camera access is off”, **Open Settings**, manual pairing, close;
- unavailable: no-camera explanation plus manual pairing;
- authorized: current viewfinder/scanner.

Do not leave a black preview as any terminal state.

- [ ] **Step 4: Run GREEN and commit**

```bash
git add apps/PortviewClient/Sources/CameraAccessModel.swift \
  apps/PortviewClient/Sources/QRScannerView.swift apps/PortviewClient/Sources/PairView.swift \
  apps/PortviewClient/Tests/CameraAccessModelTests.swift
git commit -m "fix: make camera denial recoverable"
```

### Task 6: Add the one-time, re-openable iOS walkthrough

**Files:**
- Create: `apps/PortviewClient/Sources/FirstRunState.swift`
- Create: `apps/PortviewClient/Sources/FirstRunWalkthroughView.swift`
- Create: `apps/PortviewClient/Tests/FirstRunStateTests.swift`
- Modify: `apps/PortviewClient/Sources/ContentView.swift`
- Modify: `apps/PortviewClient/Sources/SettingsView.swift`

**Interfaces:**
- Produces: injected `FirstRunStateStore` with `hasCompletedWalkthrough` and idempotent `complete()`.
- Produces: three-page walkthrough with fixed content:
  1. Portview mirrors and controls a logged-in Mac; the iOS stream is foreground-only.
  2. Pair on the same LAN/Tailscale by opening the Mac pairing window; QR is optional because code
     and manual entry remain available.
  3. Screen/input are on for paired devices; clipboard/files are off until enabled on the Mac;
     re-wake is best-effort, requires the same Apple ID and notifications, and needs a tap.
- Settings produces a **Show walkthrough** action that does not clear saved hosts or other settings.

- [ ] **Step 1: Write RED persistence tests**

Use a unique UserDefaults suite. Assert fresh state presents, completion persists across a new store,
repeat completion is harmless, and “show again” is a presentation action rather than destructive
state reset.

- [ ] **Step 2: Run RED**

Run the iOS test command from Task 5 with
`-only-testing:PortviewClientTests/FirstRunStateTests`.

- [ ] **Step 3: Implement the walkthrough and top-level presentation**

Present before Deck Home on first launch. Completing or explicitly skipping marks the walkthrough
complete. Reopening from Settings presents the same pages but does not rewrite completion state until
the user closes/completes it. Do not request camera or notification permission from the walkthrough;
requests stay contextual at scanner/pairing time.

- [ ] **Step 4: Run GREEN and commit**

```bash
git add apps/PortviewClient/Sources/FirstRunState.swift \
  apps/PortviewClient/Sources/FirstRunWalkthroughView.swift \
  apps/PortviewClient/Sources/ContentView.swift apps/PortviewClient/Sources/SettingsView.swift \
  apps/PortviewClient/Tests/FirstRunStateTests.swift
git commit -m "feat: add the iOS first-run walkthrough"
```

### Task 7: Register and route `portview://pair` URLs

**Files:**
- Create: `apps/PortviewClient/Sources/PairingURLRouter.swift`
- Create: `apps/PortviewClient/Tests/PairingURLRouterTests.swift`
- Modify: `apps/PortviewClient/Sources/ContentView.swift`
- Modify: `apps/PortviewClient/project.yml`

**Interfaces:**
- Produces: pure `PairingURLRouter.payload(from:) -> PairingPayload?`, delegating validation to the
  existing `PairingPayload(urlString:)` parser.
- `ContentView.onOpenURL` sends valid payloads through the same `session.connect(payload:discovered:)`
  path used by QR; invalid URLs are no-ops and never disconnect a live session.

- [ ] **Step 1: Write RED routing tests**

Test a valid `portview://pair?host=127.0.0.1&port=7443&pin=abcdef&name=Mac`, wrong scheme,
missing port, overflowed port, and malformed URL. Expected values must match existing
`PairingPayloadTests` behavior.

- [ ] **Step 2: Add URL registration**

In `project.yml` add `CFBundleURLTypes` with one role/editor entry whose schemes array contains only
`portview`. Regenerate the project and inspect the generated Info.plist.

- [ ] **Step 3: Implement top-level routing and run tests**

Run the iOS test command with `-only-testing:PortviewClientTests/PairingURLRouterTests`, then the full
iOS simulator suite.

- [ ] **Step 4: Commit**

```bash
git add apps/PortviewClient/project.yml apps/PortviewClient/Sources/PairingURLRouter.swift \
  apps/PortviewClient/Sources/ContentView.swift \
  apps/PortviewClient/Tests/PairingURLRouterTests.swift
git commit -m "feat: route Portview pairing URLs"
```

### Task 8: Integrated verification and handoff

**Files:**
- Modify: `.docs/ai/current-state.md`
- Modify only if verified behavior changed: `README.md`, `apps/README.md`, `CHANGELOG.md`
- Create after completion: `.docs/ai/phases/v1-release-finish-report.md`

- [ ] **Step 1: Clean stored-property build artifacts**

Run: `swift package clean`

- [ ] **Step 2: Run the full automated gate**

Run:

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make preflight`

Expected: package, Mac build/tests, and iOS simulator tests all pass.

- [ ] **Step 3: Mac human verification**

Using `/Applications/PortviewHost.app`: menu-bar-only launch; no Dock icon/window; permissions can be
granted from the popover; launch-at-login registers/unregisters; chosen free port binds on restart;
taken port falls back without erasing the preference; remembered display is chosen when present and
falls back when absent; Quit remains final.

- [ ] **Step 4: Live privacy-toggle verification**

With one authenticated client connected: defaults block both clipboard directions and both file
directions; enabling each feature permits it; disabling it during the same session stops the next
clipboard effect and an in-progress file's next chunk without reconnecting. Screen and input remain
functional throughout.

- [ ] **Step 5: iPhone human verification**

Fresh install shows the walkthrough once; relaunch does not repeat it; Settings reopens it. Camera
allow scans; camera deny shows recovery and manual pairing; Settings grant then returns to a working
scanner. Opening a valid host-generated `portview://pair` URL enters the normal connect flow; an
invalid URL leaves the current state untouched.

- [ ] **Step 6: Write the completion report and update loop state**

The report records commits, test counts, named human checks, failures/cuts, and remaining release
gates without duplicating ADR rationale. Mark Gate 4 complete in the master plan only after every
required human check passes.

- [ ] **Step 7: Commit handoff docs**

```bash
git add .docs/ai README.md apps/README.md CHANGELOG.md
git commit -m "docs: record settings and onboarding verification"
```

## Self-review checklist

- [ ] Every July 28 decision maps to at least one task and a named human check.
- [ ] No host-sensitive effect depends only on SwiftUI visibility.
- [ ] Existing `SessionCapability` checks remain intact and non-reentrant.
- [ ] Tests use fake pasteboard/files/login/camera/defaults surfaces.
- [ ] Main-window deletion occurs only after permission and failure parity.
- [ ] Walkthrough copy does not promise background streaming or guaranteed silent pushes.
- [ ] QR and URL pairing share `PairingPayload`; no second parser exists.
- [ ] `make preflight` and device checks pass before the implementation is called complete.

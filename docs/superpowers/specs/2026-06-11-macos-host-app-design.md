# macOS Host App Design

## Context

`swift run portview-host` no longer works reliably for device retesting because Screen Recording permission is attached to the terminal or harness process instead of Portview itself. Once that identity has been denied, macOS does not re-prompt consistently, and the user must manage terminal TCC state manually. The canonical Portview design already calls for a signed `.app` so Screen Recording and Accessibility grants appear in System Settings and persist under Portview's own identity.

## Goal

Add a real macOS `PortviewHost.app` target that runs the existing host server under a stable app bundle identity. The app should be good enough for ongoing on-device quality and QUIC testing: launch, request/report permissions, start the host listener, show pairing details, and keep the server alive while the app is open.

## Non-Goals

- No menu-bar-only product polish yet.
- No login item, auto-update, installer, or notarization flow.
- No host identity persistence in Keychain in this change; saved pairings still depend on the current process cert until that roadmap item is implemented.
- No rewrite of capture, transport, protocol, video, clipboard, audio, input, or file-transfer behavior.

## Approach

Use the approved approach: a full macOS app target that reuses the existing host runtime instead of shelling out to the CLI.

Create `apps/PortviewHost` as an XcodeGen-managed macOS SwiftUI app with bundle ID `dev.finklea.portview.host` and automatic signing using the same development team as the iOS app. The app links the same shared packages as `portview-host` and starts the host server directly in-process.

Extract the reusable host runtime from `Sources/portview-host/PortviewHostApp.swift` into a shared macOS-only library target named `PortviewHostCore`. The CLI target remains as a thin wrapper around that core so command-line development still works, but the TCC help text should prefer the app for normal device testing.

## Components

- `PortviewHostCore`: owns host startup, permission checks, listener creation, pairing payload generation, session serving, capture, input, clipboard, audio, and file receiving. It exposes an async host runner plus observable status callbacks for UI.
- `portview-host`: minimal SwiftPM executable entry point that invokes `PortviewHostCore` and prints the same QR/pin/status output for developers who still want CLI use.
- `PortviewHost.app`: macOS SwiftUI app target with a small status window. It starts/stops the runner, displays permission state, service name, address, port, pin, pairing URL, and current server state.

## App UI

The first version should be intentionally small:

- A status line for Screen Recording and Accessibility.
- A primary action to open System Settings for missing permissions when possible.
- Host ready details once the listener starts: service name, address, port, pin, pairing URL.
- Copy button for the pairing URL.
- Plain text guidance that the app must be quit/reopened after granting Screen Recording if macOS requires it.

Terminal QR rendering can remain CLI-only for now. The app does not need to render a QR code unless it falls out naturally from existing code.

## Permissions

At launch, the app calls the same Screen Recording and Accessibility checks the CLI uses:

- If Screen Recording is missing, request it with `CGRequestScreenCaptureAccess()` and show guidance. The grant should attach to `PortviewHost.app`, not the terminal.
- If Accessibility is missing, viewing can still run, but the app shows that input control will not work until Accessibility is enabled for `PortviewHost.app`.

Do not try to bypass TCC or automate private settings changes. The success criterion is that macOS Settings lists the host app as the permission identity.

## Data Flow

`PortviewHost.app` creates a host runner task. The runner requests/preflights permissions, enumerates displays, creates an ephemeral TLS identity, starts the existing QUIC listener, builds the pairing payload, and reports host-ready state to the UI. Accepted connections continue to be served concurrently exactly as the CLI path does today.

## Error Handling

Errors should be surfaced as user-readable UI state and CLI output:

- No Screen Recording: permission guidance, no listener start.
- No displays: show a failed state.
- Listener/cert startup failure: show the error text.
- Missing Accessibility: warning only; viewing still works.

The runner should stop cleanly when the app quits or the user stops hosting.

## Testing And Verification

Automated verification:

- `swift test --package-path <repo>`
- Build `PortviewHost.app` with `xcodebuild`.
- Build the existing `portview-host` CLI to confirm the wrapper still compiles.

Manual verification:

- Launch `PortviewHost.app`.
- Confirm Screen Recording/Accessibility prompts or System Settings entries name Portview Host / `dev.finklea.portview.host`, not Terminal/OpenCode.
- Grant Screen Recording, quit/reopen if macOS requires it, and confirm the app reaches host-ready state.
- Connect from the iPhone client and continue the pending HUD/motion retest.

## Implementation Notes

- Xcode scheme/project name follows repo convention: `PortviewHost` under `apps/PortviewHost`.
- QR in the app is optional for this change; pairing URL text is required.

# Portview v1.0 Release-Finish Plan

> **For agentic workers:** Execute one gate at a time. Each gate ends in a command or named human
> verification. Do not continue past a failed gate, invent CloudKit confirmation, initialize a new
> Beads database, push, publish, or tag without the user authorizing that action.

**Goal:** Finish Portview v1.0 as a production-capable, hardware-proven, notarized Mac host and an
archive-validated iOS client, with CloudKit re-wake and the July 28 settings/onboarding decisions
implemented and verified.

**Architecture:** Verification comes before construction. First promote the existing CloudKit
schema, then prove the already-built feature surface and re-wake path on devices. Only then execute
the separately detailed settings/onboarding plan, rerun the release gates, and prepare local release
artifacts. Production changes and device observations remain human-confirmed gates.

**Detailed implementation plan:** `docs/superpowers/plans/2026-08-03-settings-onboarding.md`

## Global constraints

- macOS 26+, iOS 26+, Apple Silicon, Swift 6.2, Xcode 26.
- Install device-test host builds only at `/Applications/PortviewHost.app`; TCC grants are path-bound.
- Never run tests against live CGEvent, pasteboard, audio, IOPM, or Keychain surfaces except the
  deliberate `KeychainIdentityStoreTests`; preserve injectable effect seams.
- `ProtocolVersion.current` stays `1`; QUIC lane A/B and per-frame streams remain cut from v1.0.
- CloudKit production state requires CloudKit Console success or explicit user confirmation.
  `cktool` export/validation does not prove that promotion occurred.
- If `.beads/` remains absent, use the tracked handoff as the queue. Do not run `bd init`.
- One commit per implementation task. Do not push, publish, upload, or create the final tag unless
  the user explicitly authorizes that separate operation.

---

## Gate 0 — Establish the release baseline

**Purpose:** Prove that the source tree is reproducible before changing external production state.

- [x] Run `git status --short --branch`; require a known branch and no unexpected changes.
- [x] Run `make bootstrap` so both generated Xcode projects and the pre-push hook are current.
- [x] Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make preflight`.
- [x] If a stored-property change has landed since the last trustworthy run, run
  `swift package clean` before accepting either red or green SwiftPM results.
- [x] Record any baseline failure before editing. A pre-existing failure does not become part of a
  later feature task unless the user explicitly expands scope.

**2026-08-03 baseline:** SwiftPM passed 734 tests in 110 suites. The Mac Xcode build then stopped
with error 65: no private-key-backed `Mac Development` certificate for team `K7CBQW6MPG` is
installed (`security find-identity -v -p codesigning`: 0 valid identities). No source fix attempted.

**2026-08-03 retry:** After installing an Apple Development identity, `make preflight` exited 0:
SwiftPM 734/734; Mac build succeeded; Mac tests 24/24; iOS simulator tests 90/90. No stored-property
source change landed between runs, so the conditional clean was not required. Non-failing output
included the existing `PortviewTransport` dependency-scan warning and a continuation-misuse warning
inside the passing non-cooperative-straggler test.

**Verify:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make preflight` exits 0:
package tests, Mac build, Mac logic tests, and iOS simulator
tests all pass.

## Gate 1 — Promote the CloudKit schema to Production (`portview-lb9`)

**Purpose:** Make the production entitlement useful. Release builds already target Production, but
beacon writes fail softly if the `HostBeacon` schema was never promoted.

### Preconditions

- [x] Sign into the Apple developer account that owns team `K7CBQW6MPG`.
- [x] Open CloudKit Console → CloudKit Database.
- [x] Select container `iCloud.dev.finklea.portview`.
- [x] In Development, confirm record type `HostBeacon` exists with the currently deployed fields:
  `hostName`, `port`, `epoch`, and `wantsReconnect`.

### Promotion

- [x] Choose **Deploy Schema Changes** for the container.
- [x] Review the proposed changes; the expected v1.0 promotion is the `HostBeacon` record type and
  its indexes/fields, with no destructive removal.
- [x] Submit the deployment.
- [x] Switch the console environment to Production and confirm `HostBeacon` is visible there.
- [x] Capture the console success state or provide explicit user confirmation in the session.

**2026-08-08 evidence:** The container initially had only the default `Users` type in both
environments. With explicit user approval, Development was given the exact additive `HostBeacon`
schema: `hostName: String`, `port: Int64`, `epoch: Int64`, and `wantsReconnect: Int64`, with no
indexes. The deployment diff added only that type and its standard `_creator`, `_icloud`, and
`_world` grants. CloudKit Console reported “The schema is deployed to Production”; Production then
showed `HostBeacon` with all four fields and no indexes, and Production schema history recorded the
type creation and role updates.

**Failure rule:** Stop on an authorization error, unexpected destructive diff, or missing
`HostBeacon`. Do not substitute `cktool` success for production confirmation.

**Verify:** Named human check — CloudKit Console shows `HostBeacon` in Production for
`iCloud.dev.finklea.portview`.

**Handoff update after success:** Mark the CloudKit item complete in `.docs/ai/current-state.md`.
Close `portview-lb9` only if the authoritative Beads database becomes available; otherwise leave no
replacement database behind.

## Gate 2 — Sitting 2: existing feature sweep (`portview-2u9`)

**Purpose:** Prove the non-auth feature surface on the build that is intended to ship. This is an
observation session, not a live debugging session.

### Stage the candidate

- [x] Build the current Mac release with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make release`.
- [x] Verify the exported app before installation:
  `xcrun stapler validate build/release/export/PortviewHost.app`.
- [x] Verify Gatekeeper acceptance:
  `spctl -a -vvv build/release/export/PortviewHost.app`.
- [x] Quit the running host, replace `/Applications/PortviewHost.app` with the exported app, and
  relaunch from `/Applications`.
- [x] Generate the iOS project with `make generate`.
- [x] In Xcode, select the attached iPhone, build the `PortviewClient` scheme, and install the
  current client. Re-pair if the device still pins an identity from another Mac.
- [x] Put Mac and iPhone on the same LAN; start from a live stream.

### Verification matrix

- [ ] **Clipboard Mac → iPhone:** copy a unique plain-text marker on the Mac; verify the client
  receives the exact marker once. The 2026-08-11 candidate passed; rerun on R2.
- [ ] **Clipboard iPhone → Mac:** send a different unique marker from the client; paste on the Mac
  and verify exact equality. **FAIL 2026-08-11:** the expected marker was absent on two independent
  reads. R2 replaces the programmatic pasteboard read with the system paste control; hardware
  verification remains required.
- [ ] **Audio:** play continuous host audio for at least two minutes; verify audible client audio,
  no periodic ticks, and recovery after a Siri/call interruption.
- [ ] **File iPhone → Mac:** send a small named file; verify one intact file appears in Downloads,
  with no duplicate or partial file.
- [ ] **File Mac → iPhone:** use the host device card to send a small named file; verify the client
  completes it and presents the Share sheet.
- [ ] **Multi-monitor:** connect with one display available, wake/connect a second display, wait up
  to two seconds for the switcher, switch to it, then switch back without restarting the host.

**2026-08-11 sitting record (superseded candidate):** notarized Release host and device-signed
Release client staged; live stream confirmed. Matrix was 1 pass, 1 fail, and 4 pending. Harness Deck
run `portview/20260811-gate2-product-test` remains historical evidence only.

**2026-08-19 R2 remediation/staging:** commits `b04400b`, `8aa4d0a`, and `b31a3fd` route reverse
clipboard through SwiftUI's system `PasteButton`, preserve the ordered outbound pump and payload
limits, and disable only clipboard send while the host is locked. The requested independent panel
cleared all material findings after repair: Ollama Cloud DeepSeek V4 Flash 0731 and GLM 5.2,
NeuralWatt Kimi K3 and GLM 5.2, plus native review; Ollama Cloud Kimi K3 could not return a verdict
because that provider lane reported insufficient balance. A fresh full preflight passed: SwiftPM
734, Mac 24, iOS 96. Release archive source `b31a3fd9f31b05574bed72bdc8755315979379ca`, Portview
1.0 (1), executable SHA-256 `9a7f70f4c13b0901b70b35446af2dcd87f72c24d5e41303494df07bb6be90271`,
was signature/privacy-manifest checked and installed on Roshar at 2026-08-19 22:05 CDT without an
agent launch. All six R2 observations are pending in Harness Deck run
`portview/20260819-gate2-product-test-r2`; its verdict remains `changes-required` until the human
sitting passes every row.

**Failure rule:** Record the build identity, exact action, observed result, and whether reconnect or
relaunch changed it. Move to the next matrix row; do not debug during the sitting. Afterward, add one
tracked roadmap item per independent defect when Beads is unavailable.

**Verify:** Named human check — all six matrix rows pass on the current release candidate.

## Gate 3 — Sitting 3: production CloudKit re-wake (`portview-uma`)

**Purpose:** Prove the best-effort CloudKit/APNs accelerator on the real production container. A
Debug host is invalid evidence because Debug intentionally omits the host CloudKit entitlement.

### Preconditions

- [ ] Gate 1 passed; Production contains `HostBeacon`.
- [ ] Install the notarized Release host from Gate 2 at `/Applications/PortviewHost.app`.
- [ ] Install a device-signed iOS client whose entitlements contain iCloud/CloudKit and
  `aps-environment`; do not use the simulator for push-delivery evidence.
- [ ] Mac and iPhone are signed into the same Apple ID, the iPhone allows Portview notifications,
  Background App Refresh is on, and Low Power Mode is off for the primary pass.
- [ ] Launch both apps once, pair, establish a stream, then return the client to Deck Home so its
  CloudKit zone/subscription bootstrap can complete.

### Primary suspended-app flow

- [ ] Background the iOS app without force-quitting it.
- [ ] In the host menu-bar popover choose **Ask iPhone to reconnect**.
- [ ] Allow a realistic best-effort delivery window; record elapsed time rather than imposing a
  false deterministic SLA.
- [ ] Verify a local notification names the Mac and offers tap-to-resume.
- [ ] Tap it and verify the client enters the existing saved-Mac reconnect path and reaches a live
  stream without manual host/port entry.

### Required edge checks

- [ ] Repeat after the Mac's LAN address changes; Bonjour re-resolution must win over the stale
  saved IP and reconnect.
- [ ] With the client already foreground and idle, nudge once; verify it reconnects in-app rather
  than posting a redundant same-host notification.
- [ ] Deny Portview notifications, foreground once, and verify the passive one-time hint appears;
  manual reconnect must remain usable.
- [ ] Force-quit the client and nudge; verify the documented limitation: iOS does not deliver the
  silent push, Portview does not claim otherwise, and manual launch/reconnect still works.

**Failure rule:** A missing push is not automatically a code defect. Record CloudKit production
confirmation, Apple-ID match, notification/BAR/Low-Power state, host beacon action, elapsed time,
and whether a later foreground fetch sees the beacon before classifying the failure.

**Verify:** Named human check — suspended-app notification → tap → live stream passes, the stale-IP
case reconnects, denied-notification copy is truthful, and force-quit behavior matches documentation.

## Gate 4 — Implement settings, privacy defaults, and first run (`portview-wyi` follow-through)

Execute `docs/superpowers/plans/2026-08-03-settings-onboarding.md` task by task. Its required outcomes
are:

- [ ] Menu bar is the Mac app; no normal host window or Dock icon remains.
- [ ] Permissions onboarding and every recovery action stay usable inline in the menu-bar popover.
- [ ] Host settings persist launch-at-login, preferred port, and default display.
- [ ] Clipboard and file transfer default off and are enforced at host effect boundaries.
- [ ] iOS first-run walkthrough appears once and can be reopened from Settings.
- [ ] Camera denial becomes an explanatory state with manual pairing and Settings recovery.
- [ ] `portview://pair` is registered and routes through the same `PairingPayload` connection path.

**Verify:** The detailed plan's focused tests pass, then
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make preflight` exits 0, followed by its
named Mac and iPhone checks.

## Gate 5 — Final archive and distribution validation

### Source and test gate

- [ ] Run `swift package clean` if any stored properties changed during Gate 4.
- [ ] Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make preflight` from a clean
  working tree.
- [ ] Confirm `ProtocolVersion.current == 1`.
- [ ] Confirm `MARKETING_VERSION = 1.0` and choose the final
  `CURRENT_PROJECT_VERSION` in `apps/Portview.xcconfig`.

### iOS archive validation

- [ ] Archive `PortviewClient` in Xcode using **Any iOS Device (arm64)** and Release configuration.
- [ ] In Organizer, run **Validate App** against App Store Connect.
- [ ] Confirm the archive contains the expected application identifier, push entitlement,
  CloudKit container, background remote-notification mode, privacy manifest, camera usage string,
  and `portview` URL scheme.
- [ ] Stop at validated archive unless the user separately authorizes upload/TestFlight release.

**2026-08-19 reconnaissance (not Gate 5 completion):** a local Release archive succeeded and was
validly development-signed with the expected bundle ID, CloudKit/APNs entitlements, background mode,
privacy manifest, and version 1.0 (1). Xcode warned that the current iPhone+iPad target supports
neither every interface orientation nor required-full-screen; choose iPhone-only versus universal
orientation behavior before App Store validation. The archive also still lacks the Gate 4
`portview://` URL scheme. App Store distribution signing, build-number availability, and Organizer
**Validate App** remain unperformed human/online gates.

### Mac artifact and install-channel decision

- [ ] Decide before tagging: keep the already-documented notarized zip as v1.0's channel
  (recommended), or explicitly expand scope to a DMG/installer task. Do not silently add packaging.
- [ ] Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make release` for the final
  commit.
- [ ] Validate staple and Gatekeeper acceptance as in Gate 2.
- [ ] Extract the zip into a clean temporary folder, drag the app to `/Applications`, and verify
  first launch, menu-bar presence, TCC onboarding, and Quit behavior.

### Release handoff

- [ ] Update `CHANGELOG.md`, `README.md`, and `apps/README.md` only for behavior actually verified.
- [ ] Mark every completed gate in `.docs/ai/current-state.md`; route durable rationale to
  `.docs/ai/decisions.md` and leave unresolved work in the roadmap.
- [ ] Run `git diff --check` and `git status --short --branch`.
- [ ] Prepare the local `v1.0.0` tag only after the user approves the final diff and artifacts.
- [ ] Push commits, tag, GitHub release, and TestFlight upload remain separate explicit approvals.

**Final acceptance:** CloudKit production schema confirmed; Sitting 2 and Sitting 3 pass; Gate 4
behavior passes tests and hardware checks; iOS archive validates; Mac zip is notarized/stapled and
clean-install tested; documentation matches the verified product; no unauthorized push/upload/tag.

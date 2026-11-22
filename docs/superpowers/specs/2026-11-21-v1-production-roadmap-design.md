# Portview v1.0 — production roadmap (design)

> Written 2026-11-21 by the lead (Fable) for the owner to approve and for an Opus lead to execute.
> It replaces "what is left for v1" in `.docs/ai/phases/v1-release-finish-spec.md`: that plan's
> Gates 2–5 are folded into the phases below. Earlier decisions stay in force unless this
> document says otherwise (`.docs/ai/decisions.md` 2026-07-27, 2026-07-28, 2026-11-19).
> Reviewed before approval by an Opus takeover check and a `gpt-6.2-sol` plan review; section 12
> records what each found and what was done with it.

## 1. Intent

Portview v1.0 is an iPhone and iPad app on the App Store plus a notarized Mac host download. The
owner's bar is **production ready for anyone on the App Store**: a non-technical stranger installs
both halves, pairs, controls their Mac, and keeps both halves updated, without help from the owner.

The July plan defined v1 as "prove what is built, document it honestly, cut what fails". That rule
still governs how work is verified. It is no longer the whole definition of done, because it never
covered what a stranger needs: finding the Mac half, updates, a way to report problems, errors they
can act on, and iPad.

### What "production ready" means here (v1.0 acceptance)

v1.0 ships when all of these are true on the build that ships:

1. **Setup without help.** A person who has never seen the project, given only the store listing
   (or its TestFlight equivalent) and their own Mac and iPhone, reaches a live session.
2. **The core works on hardware.** Screen, input (including right-click), keyboard, zoom, audio,
   clipboard, files, multiple displays, and reconnect each pass a named check with a stated pass
   threshold on real devices on the LAN, and the named remote subset passes over Tailscale.
   Re-wake is best-effort: it either passes its Phase 3 rows or is cut from 1.0 and from the docs.
3. **It works on iPad** in every orientation and in resized windows, with a hardware keyboard
   passing through to the Mac for the published key and shortcut list.
4. **Both halves stay current.** The Mac host updates itself after the user approves. When the two
   halves are incompatible, each says which one to update.
5. **Failures are actionable.** Every state in the error and recovery matrix (W1) shows a message
   that says what to do, and anything unexpected falls back to one safe generic message. No raw
   error text reaches the screen.
6. **Problems reach the owner.** Either app can produce a diagnostics export the user chooses to
   send. Nothing is sent automatically.
7. **The security claims in `SECURITY.md` hold on hardware,** including clipboard and file opt-in,
   live revoke, and denied reconnect after revoke.
8. **It survived a public beta** and met the exit criteria in Phase 4.
9. **The docs and the listing describe only verified behavior,** on OS versions that were tested.

## 2. Decisions already made by the owner (2026-11-21)

| Question | Decision |
|---|---|
| Audience | Anyone on the App Store |
| In v1 beyond the gates | Mac update notices, problem reports, iPad support, right-click, the open audio/freeze defects |
| Out of v1 | Accessibility (VoiceOver, larger text). First item after v1. |
| Launch path | Public TestFlight beta, then App Store |
| Work order | Short risk-check device session now, then build, then one full device session on the release candidate |
| Mac updates | Sparkle auto-update (the project's first third-party dependency) |
| Problem reports | Apple's tools plus a user-sent diagnostics export. No crash-reporting service. |
| iPad depth | All orientations, layouts that use the screen, hardware keyboard passthrough. Trackpad/mouse as the Mac pointer waits. |
| Tracking | Beads again, in a fresh project-local store |
| Price | Free, with an optional in-app tip or purchase |
| Mac download | A disk image (drag to Applications) |
| Site and update-feed address | A domain the owner controls, not a `github.io` address |
| The unpushed work | Push `codex/v1-release-finish` to GitHub as a branch now, as a backup. Merge to `main` after the risk check confirms the menu-bar-only app on hardware. |

## 3. Goals, non-goals, anti-goals

**Goals**: the nine acceptance points above.

**Non-goals for v1.0** (do not build; file as post-v1 if they come up):
- Accessibility pass (owner's call; recommended first post-v1 item).
- Localization. English only.
- iPad trackpad or mouse driving the Mac pointer.
- QUIC lane splitting, per-frame streams. The lanes stay dormant.
- New capture features, adaptive-bitrate work beyond what exists, locked-screen access.
- Hosted CI. `make preflight` plus the pre-push hook remains the gate.
- Analytics, telemetry, MetricKit ingestion, or any crash-reporting service.
- Mac App Store. The host cannot be sandboxed.
- Shipping the `portview-host` command-line tool. It stays a build-from-source developer tool. The
  supported configuration is one GUI host per Mac.
- Locking any feature behind a purchase. The tip is optional and unlocks nothing.
- Migrating the iOS client to Swift 6 language mode. "Swift 6.2" below means the toolchain.

**Anti-goals** (v1 has failed if these happen, even if everything "works"):
- A feature described as working that has not passed its named hardware check.
- Any user content or identifying data reaching the project or a third party without the user
  choosing to send it. Besides the session itself, three network flows exist and the privacy
  policy names each: the Mac's update check (it fetches the feed; Sparkle's system-profile
  reporting stays off), purchases (handled by Apple), and optional re-wake (a host name and
  endpoint hints through the user's own iCloud).
- Reopening the auth/pairing design. The security track stays frozen: fix defects a device session
  finds, and nothing else.
- The beta becoming a second construction phase. During beta, only fix what testers hit.

## 4. Constraints

- macOS 26+, iOS/iPadOS 26+, Apple Silicon, Swift 6.2 toolchain. No servers the project operates;
  static hosting (GitHub Pages, GitHub Releases) is allowed.
- Tests never touch live system surfaces (see repo `AGENTS.md`). Every new live surface in this
  roadmap (Sparkle, the diagnostics export, hardware keyboard) gets an injectable seam.
- Host device-test builds install only at `/Applications/PortviewHost.app`.
- No SwiftUI alerts, dialogs, or sheets from the menu-bar popover. Inline rows only. Sparkle's own
  update windows are separate windows and are allowed.
- The agent never pushes, merges, tags, uploads, publishes, creates accounts or app records, or
  changes repo/DNS settings without the owner's explicit approval for that action.
- A named human check is never recorded as passed by an agent.
- Review rules from the owner's global `AGENTS.md` apply to every workstream: `gpt-6.2-sol` plan
  review for material work, `gpt-6.1-terra` diff review and a fresh Sonnet review before a
  workstream is reported complete.

## 5. Approaches considered

**Work order.** Three options were put to the owner:
- *Test everything now, build, test everything again.* Most certainty, about twice the owner's
  device time, and every result from the first round goes stale as soon as code changes.
- *Build everything, test once.* Least device time, but a hardware surprise (audio still clicking,
  permissions unusable from the popover) appears at the end and forces a second full round.
- *Risk check, build, full test* (**chosen**). A short session now covers only the unknowns whose
  answer changes what gets built. The full matrix runs once, on the release candidate.

**Mac updates.** Sparkle (**chosen**) against a "newer version available" notice with a download
link. The notice needs no dependency and no signing key, but a non-technical user who must replace
an app by hand mostly never does, and then the App Store-updated iPhone app outruns their Mac host.

**Problem reports.** Apple's crash reports plus a user-sent export (**chosen**) against a service
such as Sentry. The service gives automatic Mac crash reports, at the cost of an account, a
dependency, and a "collects diagnostics" privacy label on a product whose pitch is "no servers".

**iPad.** Basics plus hardware keyboard (**chosen**) against layout-only (a keyboard that does
nothing in a remote-control app reads as broken) and against full pointer passthrough (larger, and
more to verify before the beta).

## 6. The roadmap

Six phases, 0 to 5. Phase 1 (owner) and the start of Phase 2 (agent) run at the same time.

```
Phase 0  Handoff        agent   Beads store, issues, branch backed up
Phase 1  Risk check     owner   one sitting on today's build   ─┐ in parallel
Phase 2  Build          agent   eleven workstreams             ─┘
Phase 3  Release cand.  both    staging feed, full device session, archive validation
Phase 4  Public beta    both    Mac beta and site first, then TestFlight
Phase 5  1.0 launch     both    App Store review, manual release, tag
```

### Phase 0 — Handoff (agent)

- After the owner approves this document: initialize a project-local Beads store at the repo's
  main checkout (local-only, no remote), confirming the selected store with `bd --sandbox where`
  before writing and that the release worktree resolves to the same store and file one issue per workstream and
  per owner action, with dependencies and the acceptance checks from this document. Bead IDs in
  older documents (`portview-uma`, `2u9`, `wyi`, `screenshare-*`) are historical.
- The earlier Beads store was lost in a machine move, which is why it was retired in September.
  This document is written so the issues can be rebuilt from it; the store is working state, not
  the record.
- Rewrite `.docs/ai/roadmap.md` as the owner-facing summary of this roadmap. Update
  `current-state.md`.
- **Branch.** The owner approved pushing `codex/v1-release-finish` to GitHub as a branch (backup).
  All work continues on it. After C3 passes, the lead asks the owner to fast-forward `main` to it
  and push; that publishes this branch plus 3 commits on local `main` that were never pushed.

### Phase 1 — Risk check (owner, one sitting, on build `eda1a8e`)

Purpose: learn the things that change what gets built. It is an observation session; nothing is
debugged during it. Stage with `make release`, install at `/Applications`, install the Release
client on the iPhone, and enable clipboard and file transfer in the menu bar. For every row,
record the build, OS versions, network, audio route, and the Quality HUD counters.

| # (C = risk check) | Check | Pass threshold | What it decides |
|---|---|---|---|
| C1 | Audio for 10 minutes on the speaker, then 10 on Bluetooth | No audible click. Gaps no more than 2 per minute on the HUD. | Whether W6 needs more than the drift fix |
| C2 | Three cold connects, then one 15-minute control session | No video stall of 3 seconds or more | Whether the old 7–10 s freeze still exists |
| C3 | The Mac app as menu-bar only: grant both permissions from the popover, turn a privacy toggle on with Touch ID, cancel one, send a file, set launch at login | Each action completes from the popover alone | Whether Gate 4's design holds on hardware |
| C4 | Connect over Tailscale from off the LAN and control for 5 minutes | Connects and stays controllable | Whether the remote claim is true today |
| C5 | Install the current client on an iPad with a hardware keyboard. Look at each screen in both orientations, then type and use a few shortcuts. | Observation only | The real size of W3 and the keys W2 must carry |
| C6 | App Store Connect preparation (see section 8): name available and app record created, export-compliance answer, storefronts, EU trader status | Each answered | Whether anything blocks upload later |

Each failure becomes an issue under W10 with the build identity, the action, and the observation.

### Phase 2 — Build (agent; workstreams W1–W11)

Each workstream is planned in detail by the executing lead just before it starts (design decisions
here are fixed; step-level plans are the builder's). "Done" for a workstream means: tests green,
`make preflight` green, both required reviews adjudicated, committed, and its hardware checks
listed for Phase 3.

**Order and dependencies.**
- W3's keyboard probe (its first task) runs before W2, because it decides what the wire must carry.
- W2 lands before the rest of W3 and before the first beta build, where the wire freezes.
- W4 starts with a spike in a real notarized export, and needs D1 (the feed address) before any
  build that will be distributed.
- W5 needs D2 (the support address). W6 waits for C1 and C2. W10 fills as sessions report.
- W11 needs the owner's App Store Connect agreements (section 8) before it can be tested.
- W1, W4's spike, W5, W7, W8, W9 and W3's probe can start immediately.

#### W1 — Interaction gaps and actionable errors (M)
- **Right-click:** a two-finger tap sends a right click (`PointerButtonKind.right` already exists).
  *Lead's call:* the owner's earlier note suggested a double tap, but two quick taps are already a
  double-click, and two-finger tap is the Mac trackpad convention. The walkthrough and a hint in
  the live view teach it.
- **Error and recovery matrix:** a finite, written list of failure states, each with its message
  and its next step, plus one safe generic fallback for anything unlisted. `SessionViewModel`
  currently shows raw `"\(error)"` for connection failures. The list covers at least: Mac not
  reachable; discovery finds nothing (with manual pairing as the way out); wrong or stale pairing;
  not approved on the Mac; device revoked; host locked; Local Network permission denied on the
  iPhone (today discovery fails silently) and on the Mac; camera denied; notifications denied;
  Screen Recording or Accessibility missing on the Mac; version mismatch; unsupported Mac or OS;
  "paired with a Mac that was reset".
- **Mac-side messages too.** The host also surfaces raw error text (`HostRunner.swift` failure
  messages, `HostAppModel.swift` reset failure). Those go through the same matrix.
- **Finding the Mac half:** the first thing a new iPhone user sees before pairing (the walkthrough
  and the empty Deck Home state) says that Portview needs the free Mac app and where to get it
  (the site address from W8). The app links to the privacy policy.
- **First launch on the Mac.** A menu-bar-only app that opens to nothing looks broken to someone
  who just double-clicked it. On first launch only, the host shows a small welcome that points at
  the menu-bar icon and leads into permissions and pairing. *Lead's call:* this is a one-time
  window and a narrow exception to "the menu bar is the app" (2026-07-28).
- **How rows are verified.** Each row is staged on hardware where it can be. Rows that cannot be
  staged (unsupported Mac or OS, purchase failures the sandbox cannot produce) are verified by
  tests through seams plus a simulator screenshot the owner approves.

#### W2 — Wire baseline, compatibility, and freeze (L, plan review required)
Nothing has shipped, so the wire can still change. It freezes at the first public beta build.
After that, any 1.x host and any 1.x client must interoperate in both directions.
- **Ratify the baseline.** `ProtocolVersion.swift` says `current` bumps for any wire change, and
  version 2 is already defined as the point where the dormant lanes switch on. Record a decision
  that changes made before the first public build redefine version 1 without a bump, and resolve
  the collision so that the *next* wire version does not switch on lanes by itself (for example
  by gating lanes on a capability instead of the version number).
- **Carry what 1.0 needs:** the keys W3's probe shows a hardware keyboard sends, press and release
  where the probe shows they are needed, and each side's app version in the hello messages.
- **Typed incompatibility.** Today a host that cannot agree a version logs and closes, and the
  client learns nothing. Add a reply that tells the client the supported range, so each app can
  say which half to update.
- `ProtocolVersion.minimum` stays 1 for every 1.x release.
- **Tolerance.** An unknown key value currently throws while decoding. Unknown keys, unknown
  message types, and longer-than-expected hellos must be skipped or refused cleanly: no crash, no
  wedged session.
- **Freeze and prove it (before the beta).** Golden byte fixtures for every message, with a test
  that fails on any change to an existing encoding. Behavioral tests for absent extensions,
  unknown keys and messages, and a genuinely incompatible range. Write the compatibility contract
  into `CONTRIBUTING.md`.
- **Interop gate (stays open until the final candidate).** When the first beta build exists, pin
  its protocol code at a tag. Every later candidate runs loopback sessions against that pinned
  copy in both directions (old host with new client, new host with old client). This part of W2
  closes in Phase 5, not Phase 2.
- The old `q48` item (a sequence counter on client feedback) is a wire change. Take it only if it
  is trivial here; otherwise it waits and uses the capability mechanism.

#### W3 — iPad (L)
- **Probe first.** A throwaway spike on a real iPad with a hardware keyboard (with C5): what
  arrives through the responder chain, press/release/cancel behavior, key repeat, text
  composition, and which shortcuts iPadOS keeps for itself. The current `KeyInputView` handles
  typed text and delete only. The probe's output is a supported key and shortcut list.
- The app already targets iPhone and iPad. What is missing: declared orientations and the
  full-screen policy flagged by the 2026-08-19 archive check, an explicit iPhone choice (portrait
  plus landscape for the live view), and layouts.
- Layouts for Deck Home, pairing, settings, the walkthrough and the live HUD use the larger screen
  and survive rotation, Split View and Stage Manager resizing; the renderer keeps the right aspect.
- Hardware keyboard passthrough for the published list. Typing works with the software keyboard
  hidden, without duplicate input. Every held key is released on focus loss, backgrounding,
  disconnect, and revoke. The support page lists the shortcuts iPadOS reserves.

#### W4 — Mac updates with Sparkle (L, security-sensitive, plan review required)
- **Spike first,** with a pinned Sparkle 2 release in the real non-sandboxed, Hardened Runtime,
  Developer ID export: manual check and scheduled check, with the popover closed, in an app with
  no Dock icon. Use Sparkle's own update window and its reminder mechanism for dockless apps.
  No unattended installs: the user approves each update.
- **Feed.** A static appcast at the permanent address (D1). Updates are signed with an EdDSA key.
  The private key lives in the owner's keychain and is never in the repo or in command arguments.
  Before the first distributed build the owner backs the key up, proves the backup restores, and
  the repo documents key rotation and manual replacement.
- **Channels and numbers.** One feed with a beta channel that testers opt into; stable users never
  see beta builds. One build number that only goes up, shared by beta and stable builds of both
  apps: `CURRENT_PROJECT_VERSION` in `apps/Portview.xcconfig`, raised by one in its own commit for
  every build that leaves this Mac. Beta builds are version 1.0 with rising build numbers.
- **Staging.** Phase 3's two builds point at a staging feed through a build setting and are never
  distributed. Distributed builds carry only the permanent address (D1).
- **Release pipeline.** `make release` builds the app, the disk image (W7) and the update archive;
  signs and notarizes; staples; verifies nested signatures and Gatekeeper; then signs the final
  bytes for Sparkle and regenerates the appcast. Building is separate from signing, which needs
  the owner. Released assets are kept outside the build directory (GitHub Releases is the
  archive). The asset is uploaded before the feed that points to it.
- **In the popover:** "Check for Updates…", the current version, and an inline automatic-check
  choice on first run.
- **Location.** The app must run from `/Applications` to update and to keep its permissions. If it
  is launched from a disk image or Downloads, the popover says so and gives the steps.
- Third-party notice for Sparkle (MIT) in the app and the repo.

#### W5 — Problem reports (M)
- **Events, not log scraping.** Each app keeps a small bounded record of redacted diagnostic
  events it writes itself (connection lifecycle, pairing, permission and update failures). Never
  recorded: pins, session tokens, clipboard contents, file names or contents, IP addresses beyond
  "LAN" or "overlay".
- **Export.** "Send diagnostics" in iOS Settings and in the Mac popover builds one bounded,
  allowlisted export: app version and build, OS, device model, settings that matter, and the
  recent events. On the Mac it may attach Portview's own crash reports from the user's
  diagnostic-reports folder. The user sees exactly what is in it, then shares it (iOS share sheet,
  Mac save panel) with instructions for where to send it. Nothing is sent automatically.
- **Logging.** The same failure points are also logged through `os.Logger` with privacy
  annotations, for Console and sysdiagnose.
- **Privacy label.** Audit the actual send flow against Apple's rules before choosing the label.
  If the export cannot keep "Data Not Collected", the export shrinks; the label does not change
  without the owner's decision.
- Symbol files (dSYMs) for every distributed build of both apps are kept with the release assets.
- iPhone crash reports otherwise arrive through App Store Connect and TestFlight with no code.

#### W6 — Media defects (M, shaped by C1 and C2)
- **Drift.** The presentation clock offset is set once and never refined, which adds about 94 ms
  of audio/video lag per hour. Fix it. Pass: lag grows by no more than 40 ms over a 60-minute
  session. Measurement: the lead supplies a short flash-and-click clip; the owner films the iPhone
  playing it with a second phone in slow motion (240 frames per second, about 5 ms resolution) at
  minute 1 and minute 60, and the flash-to-click offsets are compared.
- **Reconnect gaps.** 5.9–9.4 s after a reconnect the host skipped ten runs of audio, each
  20–300 ms (suspected send stall overflowing the capture buffer). Pass: no audible gap in the 30
  seconds after each of five reconnects.
- Whatever C1 and C2 show. If a defect survives two fix attempts, stop and bring the owner the
  cut-or-ship decision, per the 2026-07-27 rule.

#### W7 — Mac install experience (S)
- The download a person gets from the site is a notarized, stapled disk image with a
  drag-to-Applications layout (owner's decision, replacing the bare zip for people).
- Uninstall instructions on the support page (app, login item, permissions, keychain items).

#### W8 — Site, policy, and store listing (M, mostly writing)
- A small static site: what Portview is, the Mac download, requirements, a support page (setup,
  troubleshooting, known limitations, reserved iPad shortcuts, contact), the privacy policy, and
  the update feed.
- Store listing: name, subtitle, description, keywords, category, age rating answers, privacy
  answers, price (free, with the tip from W11), screenshots for 6.9-inch iPhone and 13-inch iPad
  taken from simulators connected to a real host.
- App Review notes: Portview mirrors the user's whole Mac generically (the LAN-only clause of
  guideline 4.2.7 applies to mirrors of specific software); it also works over the user's own
  Tailscale network, stated plainly; where to get the exact compatible Mac build; the permission
  and approval steps; step-by-step test instructions; a screen recording. Keep a LAN-only launch
  as the fallback if review objects to remote use.
- Export compliance: a written basis for the owner's answer (the apps use Apple's system
  cryptography: QUIC/TLS, Curve25519 signatures, HMAC, HKDF).
- TestFlight: beta description, "what to test", and a short way for testers to report "set up and
  controlled my Mac" or where they got stuck.
- A beta announcement the owner can post to recruit testers.
- `SECURITY.md`: supported-versions table, and a note to enable private vulnerability reporting.
- README install section updated when the beta is live.
- The agent drafts all of this in the repo. The owner publishes it.

#### W9 — Small carried-forward fixes (S)
Only the ones a user can hit:
- **Held input on revoke or teardown** (required, not optional): a key or mouse button held when a
  device is revoked or a session ends is released by the host.
- Partial files left behind when a transfer is cut off.
- The two timing-dependent clipboard tests, which will flake in the release gate.

#### W10 — Findings from device sessions (size unknown)
Every failure from Phase 1, Phase 3 and the beta lands here. A failure in a row that an acceptance
point depends on blocks v1. After two failed fix attempts on one defect, the owner decides: keep
fixing, or cut the feature and its claim from 1.0. Remote use over Tailscale is a headline claim;
cutting it means changing the README, the listing and the review notes.

#### W11 — Optional tip (S–M)
- The app is free. iOS Settings gets a quiet "Support Portview" row offering a few one-time tip
  amounts through Apple's in-app purchase. *Lead's reading of the owner's choice:* a tip jar that
  unlocks nothing and never interrupts or nags; say so at approval if a real unlock was meant.
- The Mac host has no purchase flow (in-app purchase is not available outside the Mac App Store).
- No server and no account: purchases go through Apple, and the app stores nothing about them.
  The privacy answers are re-checked with this in place.
- Purchase failures and the "purchases not allowed on this device" case have rows in W1's matrix.

### Phase 3 — Release candidate (both)

The agent cuts a release candidate: version 1.0, a new build number, `make preflight` green,
iOS archive built. The owner signs and notarizes two consecutive Mac builds (N and N+1) and
publishes a **staging** update feed, so the update check below uses real Developer ID builds.

The owner also uploads the candidate to TestFlight for **internal** testers only (no Beta App
Review is needed for internal testing), with the tip products created, so the re-wake and tip rows
run on a store-signed build.

Then the owner runs the device sessions (about three hours for the owner's own matrix; it can be
split). Rows run on the LAN unless they say otherwise. The agent prepares a printable checklist with a unique marker per row and a pass
threshold per row. Nothing is debugged during a session.

The matrix:
- **Gate 2** (all six rows): clipboard both ways, audio with a Siri/call interruption, files both
  ways, multiple displays. Clipboard and files are enabled first.
- **Gate 3**: re-wake on the Production iCloud container, with the original preconditions and the
  manual-fallback checks, on the internal TestFlight build. Pass: with the app suspended (not
  force-quit), at least 3 of 5 nudges produce the notification within 2 minutes, and tapping it
  reaches a live session. 1 or 2 of 5 is inconclusive and is repeated once; 0 of 5, or a second
  inconclusive run, means re-wake is cut from 1.0 and from the docs.
- **Gate 4**: the 17 checks in `.docs/ai/phases/v1-release-finish-report.md`.
- **Security regression** (auth code was touched since Sitting 1): on a fresh install clipboard
  and files are off and blocked in both directions; revoke a connected device and watch the
  session die; the revoked device is refused on reconnect; a transfer cut off by revoke leaves
  nothing behind; no key stays held.
- **Earlier features never confirmed on hardware:** zoom and magnifier (no tearing, smooth pan,
  crisp at about 5×, no crash on rapid zoom, several minutes of high-zoom panning on moving
  content); keep-awake and the "capture paused" overlay when the Mac locks; 6-digit code pairing;
  quality settings taking effect; a saved Mac reconnecting after its IP address changes.
- **New in this roadmap:** right-click; each stageable row of the error and recovery matrix; iPad
  in every orientation, Split View and Stage Manager; the hardware key and shortcut list;
  version-mismatch messages; the Mac first-launch welcome.
- **Diagnostics:** export from both apps; the preview matches the file exactly; it contains only
  the listed fields; nothing leaves the device until the user shares it.
- **Install:** from the disk image into Applications; launching from the disk image or Downloads
  shows the "move it" guidance.
- **Tip:** on the internal TestFlight build: a tip completes, a cancelled tip changes nothing, and
  a device with purchases disabled shows its message.
- **Links:** every link in the app, the site, the listing draft and the review notes opens the
  right thing.
- **Update:** from build N to N+1 through the staging feed. After relaunch: capture and input
  still work without re-granting, the paired iPhone reconnects, settings and the login item
  survive. If macOS asks for a permission again, the app's recovery path handles it.
- **Reliability:** a 60-minute session (drift threshold from W6, no stall of 3 s or more); five
  reconnects after dropping Wi-Fi, each back within 10 seconds without touching the Mac; the Mac
  sleeping and waking; the app backgrounded and resumed; the host quit and relaunched.
- **Remote subset over Tailscale** (off the LAN, for example on cellular): connect; pointer
  control including right-click; typing; audio for 5 minutes; clipboard both ways; one file each
  way; one reconnect after dropping the network; a 15-minute session with no stall of 3 s or more.
- **Oldest supported OS:** a smoke run (install, pair, control) on macOS 26 and iOS 26, using a
  virtual machine and the iOS 26 simulator if no hardware is available. If that cannot be done,
  the minimum OS is raised to what was tested (owner decision at that point).
- **Uncoached setup:** one person who has not seen the project, with a clean Mac user account and
  their own iPhone or iPad, starts from the listing or TestFlight page alone. The owner watches
  and records where they get stuck, without helping.
- **Gate 5:** archive with App Store signing and run Validate App.

Failures become W10 issues. Fixes are batched, and only the affected rows are re-run, unless a fix
touches transport, auth, or capture, which re-runs the Gate 2 and security rows as well.

### Phase 4 — Public beta (both)

Order matters, because Apple reviews beta builds and a reviewer needs the Mac half:
1. Owner publishes the site and the Mac beta (GitHub pre-release, feed live, beta channel).
2. Owner confirms the download link, the feed and every link in the review notes work.
3. Owner submits the build for Beta App Review with the review notes, and submits the tip
   products for review with it (Apple requires offered purchases to work and be reviewable).
4. Owner opens the public link and posts the announcement.

The wire is frozen from the first beta build. Feedback arrives through TestFlight feedback and
crash reports, diagnostics exports sent to the support address, and GitHub issues. The lead
triages weekly into Beads: fix now, fix before 1.0, or post-v1. At least one Mac update goes to
beta users through Sparkle.

**Exit criteria** (*lead's proposal; the owner can change the numbers — D3*):
1. At least 14 days of beta.
2. At least 10 external testers report a completed setup, pairing and control session, including
   at least 2 on iPad.
3. At least 3 testers confirm a Sparkle update worked and kept their permissions and pairing.
4. No open issue that loses data, breaks a security claim, blocks setup or connection, or crashes
   for more than one tester. "Explained" is not "closed".
5. The owner has used the candidate as their own daily remote for a week.

### Phase 5 — 1.0 launch (both)

- **Truth audit.** The lead checks the README, `SECURITY.md`, the changelog, the site, the listing
  and the review notes against the rows that passed, and removes or marks anything unproven. The
  owner approves the result. (The same audit runs once before the beta opens.)
- Promote the qualified TestFlight build where possible, so the beta's evidence still applies. If
  anything changes, re-run the affected rows. Record the exact commit, build numbers and the Mac
  artifact hash.
- Owner actions, each separately approved, in this order: publish the Mac 1.0 release and the
  stable feed; verify the live download and links; submit for App Store review with **manual
  release** selected; after approval, release; then a smoke test from the public storefront to a
  live session. Then push the `v1.0.0` tag and GitHub release and flip the site from beta.
- If App Review rejects, the lead drafts the response or the fix; the owner submits.
- One week of watching crash reports and issues before any post-v1 work starts.

## 7. Owner decisions still open

- **D1 — the exact hostname** on the owner's domain for the site and the update feed (for example
  a `portview` subdomain). Needed before the first distributed build; the DNS change goes through
  the owner's DNS repo.
- **D2 — the public support address** for diagnostics exports and the store listing.
- **D3 — beta exit numbers**, if the owner wants different ones.
- **D4 — the tip amounts**, and confirmation that the tip unlocks nothing (W11).

## 8. Owner-only actions (the agent prepares, the owner does)

- Device sessions (Phases 1, 3, 5) and recruiting the uncoached tester.
- App Store Connect: name and app record, listing, privacy answers, price, storefront
  availability, EU trader status, the export-compliance answer, TestFlight, submission, release.
- For the tip: Apple's paid-apps agreement, tax and banking details, and creating the tip
  products.
- Creating, backing up and restore-testing the Sparkle signing key; signing releases.
- Enabling GitHub Pages and private vulnerability reporting; any DNS change.
- Recruiting beta testers (the lead drafts the announcement), and answering the support address.
- Every push, merge, tag, release, and upload. Approving the privacy policy text.

## 9. Left to the builder

- Step-level plans for each workstream, written just before it starts.
- All implementation structure: types, files, seams, test design.
- iPad layout specifics; the key list (from the probe); the capability mechanism in W2.
- Wording of error messages, walkthrough changes, site copy and listing copy (owner reviews copy
  before it is published).
- The format and size bounds of the diagnostics export.
- How testers report a completed setup during the beta.

## 10. How the executing lead works

- One workstream at a time through plan → implement (Sonnet implementers) → per-task review →
  whole-diff review (`gpt-6.1-terra` plus a fresh Sonnet reviewer) → commit. Under an Opus lead a
  failed Sonnet task returns to the lead.
- Beads holds the task state; `.docs/ai/roadmap.md` and `current-state.md` stay short and
  owner-readable; durable rulings go to `decisions.md`.
- New ideas found along the way are filed as post-v1 issues, not built.
- Stop and ask the owner for: anything in section 8, a defect that survives two fix attempts, a
  change to an acceptance point, or a finding that touches the frozen auth design.

## 11. The old backlog, triaged

The roadmap file lists 37 items restored from a July snapshot of the old tracker. Their fate:

| Old items | Fate |
|---|---|
| Mutual auth (`1nt`, `5yw`, `7jl`, `9m2`), re-wake code and its review (`8n1`, `djx`), lane splitting phase 1 (`w6n`), settings scope (`l4y`), `8z9`, `s86`, `e00`, notarization (`cqv.2`) | Already done; the snapshot was stale. Update path → W4. |
| Concurrency epic (`523`) | Children all closed. The lead confirms by reading current code (not a hardware check) that the capture-engine race and the first-read deadline are closed, as part of W9; if either is open it is a v1 fix. |
| Device checks: zoom (`89q`, `pkb`, `b27`, `5ep`, `11s`), display refresh (`ed4`), keep-awake and lock overlay (`1wm`), audio interruption (`36p`), quality controls and saved-Mac refresh (`43i`), 6-digit pairing (`6j7`), menu bar and permissions (`er1`), Tailscale (`ve5`), re-wake (`8n1.4`) | Folded into the Phase 1 and Phase 3 matrices. |
| Release readiness epic (`cqv`), polish umbrella (`ux7`) | Replaced by this roadmap. |
| A/V sync (`ins`) | The user-visible part is W6's drift fix. The rest is post-v1. |
| Zoom "pop" on re-crop (`2ee`), magnifier tuning (`2ws`) | Post-v1 unless the Phase 3 zoom rows fail. |
| Client-feedback sequence counter (`q48`) | Decided inside W2. |
| Client code decomposition (`jfj`), media foundation (`ja1`), lane A/B (`w6n.6`), per-frame streams (`10p`) | Post-v1. |
| Bitrate-mode test gap (`jc3`) | Dropped; its scope was lost with the old store. |

## 12. Review record

**Opus takeover check** (eight questions, five contradictions):
- Adopted: an owner for session failures (W10); the old backlog triage (section 11); beta
  versioning and channels (W4); the command-line tool is not shipped (section 3); label-versus-
  export precedence (W5); export compliance and tester recruitment as owner actions (section 8);
  the push is 29 commits (Phase 0); the disk image went to the owner, who chose it; Swift 6.2 means the
  toolchain; the app is already universal; why Beads was retired (Phase 0).
- Sent to the owner: price. Answer: free with an optional tip, which added W11.

**`gpt-6.2-sol` plan review** (three Critical, nine Important), each checked against source:
- Adopted in full: Mac host and site live before Beta App Review; export compliance, storefronts
  and EU trader status before upload; the wire baseline, lane-version collision, typed
  incompatibility reply and interop tests (W2); Sparkle spike, dockless update UI, signed disk
  image pipeline (W4); channels, build numbering, asset retention, key backup and rotation (W4);
  update proof on two Developer ID builds through a staging feed (Phase 3); keyboard probe before
  W2 and key release on focus loss (W3); uncoached setup test, both-side permission denial, finite
  error matrix (W1, Phase 3); pass thresholds (Phase 1, W6, Phase 3); held-input release required
  and security regression rows (W9, Phase 3); beta exit by recorded outcomes, promote the
  qualified build, manual release (Phases 4–5).
- Adopted in part: diagnostics. MetricKit ingestion and broad log export are cut as recommended;
  the Mac may still attach its own crash reports, because otherwise Mac crashes never reach the
  owner.
- Rejected: none.

**Pre-commit reviews of the revised document** (`gpt-6.1-terra` and a fresh Sonnet reviewer):
- Adopted from `gpt-6.1-terra`: an internal TestFlight upload in Phase 3 so the re-wake and tip
  rows have a store-signed build; W2 split into a pre-beta freeze and an interop gate that stays
  open until the final candidate; a named remote subset over Tailscale (and acceptance point 2
  reworded to match); a pass rule for re-wake; the privacy boundary stated for update checks,
  purchases and re-wake; tip products submitted with the build; a measurement method for drift.
- Adopted from Sonnet: a truth audit of docs and listing; how unstageable error rows are
  verified; explicit rows for privacy defaults, diagnostics contents, install from the disk
  image, the tip, and links; the build-number source; `minimum` stays 1; staging feed versus the
  permanent address; Mac-side raw errors; the Mac first-launch welcome; risk-check rows renamed
  C1–C6 to avoid clashing with the older "R3/R4 sitting" names.
- Rejected from Sonnet: an owner for deploying the Production iCloud schema. It was deployed at
  Gate 1.
</content>

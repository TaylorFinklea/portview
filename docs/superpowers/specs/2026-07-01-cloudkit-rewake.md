# Spec — CloudKit silent-push re-wake (no hosted server)

> Lead-authored (Fable 5, 2026-07-01) for bead `screenshare-8qi`. Chosen path per the
> user decision recorded 2026-07-01 (decisions.md): background re-wake rides the user's
> own iCloud via CloudKit subscriptions — fits the "no servers we host" constraint.
> Anchors the M6 "reconnect + APNs re-wake" polish item.

## Review fold (2026-07-02 — platform-reality must-fixes)

A design review + against-source verification folded these load-bearing platform fixes
into the body (all file:line refs verified 2026-07-02):
1. **Epoch source** — wall-clock micros / persisted counter, NOT host uptime (§1); uptime
   regresses on reboot and the dedupe would silently eat every wake for days.
2. **iOS silent-push plumbing** — the entitlement, background mode, APNs registration,
   delegate adaptor, and notification authorization that DON'T exist today, all now
   enumerated (§2a) so `rewake-client` can't ship a build that receives/posts nothing.
3. **Zone creation** — assigned to the host (create-on-first-write) with client
   `zoneNotFound` tolerance (§0); previously unassigned → both ends silently dead.
4. **Per-host `lastHandledEpochs` map** — a scalar lets one Mac permanently suppress
   another's wakes (§3).
Plus: `.changedKeys` save policy (§1), the notifications-denied / force-quit / DHCP-move
failure rows (§Failure modes), and the `accountStatus` mismatch caveat. This is plain
platform / CloudKit / iOS-lifecycle work — no cryptographic content.

## Problem (verified)

The iOS session is foreground-only. Backgrounding suspends the app and drops the QUIC
connection; the in-app `reconnectLoop` (SessionViewModel.swift:656-686) only covers
mid-session drops while the app stays foreground, inside a 30 s window
(`reconnectWindow`, SessionViewModel.swift:84). Once the app is suspended there is no
path back: the host cannot reach the phone, and the user returns to a dead session that
must be re-dialed manually after the window has long expired.

## Hard iOS constraint (shapes the whole design)

**A silent push cannot re-foreground an app.** iOS grants a suspended app ~30 s of
background execution on a `content-available` push; it never programmatically brings UI
forward. So the deliverable is NOT "the stream resumes in the background" — it is:

1. background: verify the host is reachable and pre-warm state, then
2. post a **local notification** ("<Mac> is ready — tap to resume"), and
3. on tap, deep-link straight into the existing reconnect path so the stream is live
   within ~1-2 s of foregrounding.

Any design promising more than tap-to-resume is over-promising against the platform.
Additionally, silent pushes are **best-effort**: iOS budgets/coalesces them per app
(roughly a handful per hour under Low Power Mode or poor standing). The feature is a
convenience accelerator, never a correctness dependency.

## Design

### 0. Shared CloudKit container

One container, `iCloud.dev.finklea.portview`, added to BOTH app targets (host
`dev.finklea.portview.host`, client `dev.finklea.portview`; same team). All records
live in the **private database** (the user's own iCloud — zero third-party server,
zero data visible to us), in a custom zone `PortviewSignals` (custom zone required for
`CKRecordZoneSubscription`).

**Zone creation is the host's job, and both sides tolerate its absence.** CloudKit does
NOT auto-create a zone on record save, and a `CKRecordZoneSubscription` cannot be saved
against a zone that doesn't exist — so leaving this unassigned makes both ends fail with
`zoneNotFound`, indistinguishable from the "iCloud down" row. Rules: (a) the **host**
creates `PortviewSignals` (a `CKModifyRecordZonesOperation`, idempotent) immediately
before its first beacon write; (b) the **client** subscription bootstrap must not assume
the zone exists — on the phone-first install order it will not. The client saves the zone
(idempotent create) before saving the subscription, and its background handler treats
`zoneNotFound` as "not ready yet, no-op" rather than an error to swallow. The §1
"log-and-drop errors" rule for host beacon writes explicitly does NOT cover `zoneNotFound`
— that one must trigger a create-then-retry.

Requirement this creates: host Mac and iPhone must be signed into the **same Apple
ID**. Fail soft when they aren't (feature silently unavailable; everything else works).

### 1. Host beacon (Mac writes "I am reachable")

Record type `HostBeacon`, **one record per host identity**, `recordName` = the host's
pin fingerprint hex (stable across restarts thanks to the persistent TLS identity — see
TLSIdentity.swift). Fields (all CK-native types):

- `hostName: String` — Bonjour/display name
- `port: Int64` — the persisted listening port
- `epoch: Int64` — monotonically increasing per write, sourced from **wall-clock micros**
  (`Int64(Date().timeIntervalSince1970 * 1_000_000)`) or a UserDefaults-persisted counter
  — **NOT host uptime.** Uptime resets to ~0 on reboot, so `epoch <= lastHandled → ignore`
  (§3) would silently discard every legitimate wake for days after a restart — precisely
  the reboot scenario this feature exists for. Do NOT copy the
  `UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000)` idiom at
  `HostRunner.swift:534`: that value is a relative RTT/clock-offset reference for
  Ping/Pong, correct there because reset-on-reboot is fine; it is wrong as a durable epoch.
  Lets the client discard stale/duplicate wakes.
- `wantsReconnect: Int64` (0/1) — distinguishes a routine liveness update from an
  explicit "nudge the phone" ask

Host writes the beacon (upsert by recordName) on: hosting start, persisted-port change,
and an explicit **"Ask iPhone to reconnect"** menu-bar action (`wantsReconnect = 1`).
Do NOT write on a timer — every write costs a push against the phone's silent-push
budget. Writes are fire-and-forget with one retry; CloudKit being down must never
affect hosting (wrap in its own task, log-and-drop errors — **except `zoneNotFound`,
which triggers create-then-retry**, §0). **Upsert needs an explicit save policy:**
`CKModifyRecordsOperation` defaults to `.ifServerRecordUnchanged`, which fails every write
after the first with a server-record-changed conflict — use `.changedKeys` (or fetch →
mutate → save) so the second and later beacons actually persist.

### 2. Client subscription + background handler

- One `CKRecordZoneSubscription` on `PortviewSignals` with
  `notificationInfo.shouldSendContentAvailable = true` (no alert/badge/sound —
  silent). Zone subscription > query subscription here: fires on any beacon change,
  no predicate maintenance, one subscription to manage idempotently at launch.
- `didReceiveRemoteNotification` background handler:
  1. Fetch changed records in the zone (`CKFetchRecordZoneChangesOperation` with a
     stored change token).
  2. Feed each beacon into the pure `ReWakeDecision` (below) against the saved-hosts
     store and the last-handled epoch.
  3. If the decision says act: attempt a **short QUIC reachability dial** to the saved
     endpoint (pinned, bounded ≤5 s — sockets are permitted inside the background
     window). On success post the local notification; on failure stay silent (a
     notification that leads to a dead host is worse than none).
  4. Call the completion handler within the budget regardless.
- Notification tap deep-links to the saved host entry and enters the normal
  saved-Mac reconnect flow (the same path a manual tap takes — no new streaming code).
- If the push arrives while the app is FOREGROUND, skip the notification and kick the
  in-app reconnect directly.

### 2a. iOS silent-push plumbing (ALL required; NONE exist today)

Verified against the client tree (2026-07-02): there is **zero** UNUserNotification,
`registerForRemoteNotifications`, CloudKit, or APNs plumbing anywhere in
`apps/PortviewClient/`, and `PortviewClientApp.swift:1-10` is a pure SwiftUI `@main App`
with no delegate seam. A `CKRecordZoneSubscription` content-available push rides APNs, so
without every item below the background handler simply never fires and the local
notification is never delivered — the feature ships dead with no error. `rewake-client`
(bead 3) MUST include all of:

1. **`aps-environment` entitlement** (push capability) alongside the iCloud/CloudKit
   container entitlements, in a new `.entitlements` file wired into both `project.yml`
   files (none exists today — signing changes are human-verified, not headless).
2. **`UIBackgroundModes: [remote-notification]`** in `Portview-Info.plist` — without it a
   `content-available` push cannot wake the suspended app.
3. **`UIApplication.registerForRemoteNotifications()`** at launch — CloudKit subscription
   pushes require APNs registration even though there is no server token exchange.
4. **A `@UIApplicationDelegateAdaptor`** added to `PortviewClientApp` carrying
   `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)` — the pure-SwiftUI
   app has no `AppDelegate`, so the adaptor is the only place the background callback can
   land. Call the completion handler within the budget on every path.
5. **`UNUserNotificationCenter` authorization** — posting a `UNNotificationRequest` without
   granted authorization is *silently dropped*, and the local notification IS the entire
   user-visible deliverable (§Hard iOS constraint). Request it once (at pairing or first
   background-feature enable), and assign the `UNUserNotificationCenterDelegate` **before
   launch completes** or a tap on the notification from a terminated app drops the response
   (the exact path `rewake-verify` checks). Denied authorization → the feature is inert;
   surface one passive hint, never block.

Note the interaction with bead sequencing: this plumbing touches signing/provisioning on
both apps, so `rewake-client` stays `tier_floor: senior` with a human-gated device-verify
(`rewake-verify`); push delivery itself is not simulator-testable.

### 3. Pure, package-testable core (TDD first)

New pure types (no CloudKit import — CK types stay at the app edge):

- `HostBeaconRecord` — struct + `init?(recordFields: [String: Any])`-style mapping and
  the inverse, so the CK record ↔ struct codec is unit-tested without CloudKit.
- `ReWakeDecision.evaluate(beacon:, savedHosts:, lastHandledEpochs:, now:) ->
  Action` where `Action ∈ {ignore, reachabilityProbe(endpoint, pin), notify(...)}` —
  encodes: unknown host → ignore; epoch ≤ the last-handled epoch **for this beacon's own
  host** → ignore (dedupe/replay); `wantsReconnect` vs routine update policy; rate-limit
  (min interval between notifications for the same host).
- **`lastHandledEpochs` MUST be a per-host map, not a scalar** — keyed by the beacon's
  `recordName` (= the host pin fingerprint hex; the same durable identity `SavedHostsStore`
  already dedupes on — `SavedHostsStore.swift:43` stores `[SavedHost]` with a stable
  `pinHex`). Epochs are independent per-host clocks; a single scalar means the Mac with the
  larger epoch (e.g. a long-running desktop) permanently suppresses every wake from a
  just-rebooted laptop whose fresh epoch reads as a replay. Persist the map (UserDefaults,
  JSON — mirrors `SavedHostsStore`'s persistence) alongside the change token and rate-limit
  timestamps.

Placement: these are client-side but pure — put them in the SwiftPM package (new
`PortviewClientCore` target if `screenshare-1j0` has landed; otherwise
`PortviewTransport` is the wrong home — park them in a new small
`PortviewRewakeCore` target rather than the app bundle, so `swift test` covers them).

### 4. Explicitly out of scope

- Waking a **sleeping Mac** (that is Wake-on-LAN territory, different feature).
- Background streaming / PiP.
- APNs direct (needs our server + key), PushKit VoIP (App Store rejection risk),
  Live Activities (wrong tool). Recorded as rejected alternatives.

## Failure modes & caveats (disclose in UI/docs)

| Mode | Behavior |
|---|---|
| No iCloud account on the phone | `CKContainer.accountStatus` = `.noAccount`/`.restricted` → feature unavailable; one passive hint, never block. **Caveat:** `accountStatus` reports whether *an* account is signed in, NOT whether Mac and phone share the *same* Apple ID — a genuine Apple-ID *mismatch* surfaces only as the host's records never appearing in the phone's private DB (silent). Document as "same Apple ID required"; do not claim `accountStatus` detects the mismatch. |
| `PortviewSignals` zone missing (install-order race, phone-first) | Host create-on-first-write covers it; client treats `zoneNotFound` as "not ready", no error (see §0) |
| iCloud down / no network | Beacon writes drop silently; manual reconnect unaffected |
| Notifications denied (`UNUserNotificationCenter` not authorized) | Handler runs, probe may succeed, but nothing is posted — feature inert. Detect authorization status; show one passive hint (§2a). Indistinguishable-from-nothing without this row. |
| App force-quit, or Background App Refresh off | iOS delivers **no** content-available push to a force-quit app, and none with BAR disabled — the feature cannot wake the app at all. Best-effort, documented; not a correctness path. |
| Silent-push budget exhausted / Low Power Mode | Wake arrives late or never — best-effort (APNs priority-5, tens of seconds to minutes) |
| Host moved (DHCP address change — the common post-reboot case) | The saved endpoint is stale, so a probe/tap that dials it hard-fails. The beacon carries the host's current `port`; the probe must prefer a live Bonjour re-resolve by host name (the existing `reconnectEndpoints(among:)` path) before the saved IP, else surface "couldn't reach — open the app on Wi-Fi". |
| Push arrives but host gone | Reachability probe fails → no notification (no false promises) |
| Replayed/duplicate push | per-host `epoch` dedupe in `ReWakeDecision` (§3) |

## Beads this spec gates (file on acceptance)

1. `rewake-core` — pure `HostBeaconRecord` + `ReWakeDecision` + tests. No CloudKit.
   `lastHandledEpochs` is a **per-host map** keyed by recordName (§3); ship a
   `ReWakeDecision` test **"host rebooted, epoch regressed"** (a beacon whose wall-clock
   epoch is below the stored per-host value from a prior boot is still handled when
   `wantsReconnect = 1`, i.e. the dedupe never eats a nudge) and a test proving one host's
   epoch never suppresses another's. `tier_floor: junior`, `complexity: S`.
   Verify: `swift test --filter ReWake`.
2. `rewake-host` — host beacon writer behind an injectable `BeaconStore` protocol
   (CloudKit impl at the app edge; in-memory in tests) + **`PortviewSignals` zone create
   (idempotent, before first write)** + wall-clock/persisted-counter epoch (NOT uptime,
   §1) + `.changedKeys` save policy + menu-bar nudge action.
   `tier_floor: senior`, `complexity: M`. Verify: package tests + host build.
3. `rewake-client` — the full §2a plumbing (entitlements file with `aps-environment` +
   iCloud/CloudKit container, `UIBackgroundModes: [remote-notification]`,
   `registerForRemoteNotifications`, `@UIApplicationDelegateAdaptor` +
   `didReceiveRemoteNotification:fetchCompletionHandler:`, `UNUserNotificationCenter`
   authorization + delegate) + idempotent zone/subscription bootstrap that tolerates
   `zoneNotFound` + background handler + local notification + deep link into the existing
   saved-Mac reconnect path (prefer Bonjour re-resolve over the stale saved IP).
   `tier_floor: senior`, `complexity: L`. Verify: iOS build + sim tests for the decision
   plumbing; push delivery + the entitlements are device-gated.
4. `rewake-verify` — human device-verify: background the app, click "Ask iPhone to
   reconnect" on the Mac, tap the notification (from both suspended AND terminated states),
   stream resumes; and the "notifications denied → inert" path shows the passive hint.

Dependency note: 1 → 2/3 (both consume the pure core); 4 last. Entitlement work
(container + push provisioning) touches both xcodegen `project.yml` files and a new
`.entitlements` file — signing changes are human-verified, not headless.

## Addendum (2026-07-08 — beads filed)

Filed as **epic `screenshare-8n1`** (.1 rewake-core, .2 rewake-host, .3 rewake-client,
.4 device-verify), deps as the note above. `PortviewClientCore` has landed
(`screenshare-1j0`), so the §3 pure types go there — the `PortviewRewakeCore` fallback is
moot. Line drift since the 2026-07-02 verification: the systemUptime Ping/Pong idiom §1
warns against copying is now at `HostRunner.swift:602` (was ~534).

# Phase 1 risk check — staging steps and checklist

> For the owner. Roadmap: `docs/superpowers/specs/2026-11-21-v1-production-roadmap-design.md`,
> Phase 1. Issues: `portview-p1-stage` (this file), `portview-p1` (the sitting).
> Print it from any Markdown preview, or fill it in on screen.

This sitting answers six questions that change what gets built next. It is an observation
session: nothing is fixed or debugged during it. When a row fails, write down what you saw and
move to the next row.

**Time.** Staging takes about 25 minutes, of which about 10 are waiting for Apple's notarization.
The sitting takes about 90 minutes. C6 can be done at the Mac during the C1 listening time, and
C4 or C5 can move to another day if needed; C3, C2 and C1 belong together, in that order.

**Who records what.** You record every result. An agent never marks a row as passed. Afterwards,
give the filled-in sheet (or tell the results) to the lead agent, which copies them into this file
as "owner reported" and files one issue per failure under `portview-w10`.

## What you need on the desk

- [ ] The Mac, plugged in, with Xcode signed in to your Apple ID.
- [ ] The iPhone and the iPad, charged, unlocked, each on a USB cable for staging.
- [ ] A hardware keyboard for the iPad.
- [ ] Bluetooth headphones or a Bluetooth speaker that pair with the iPhone.
- [ ] Tailscale signed in on the Mac and on the iPhone, in the same tailnet.
- [ ] Mobile data on the iPhone (for C4), or a second network that is not your home network.
- [ ] Something that plays continuous audio on the Mac for 20 minutes (music, not a podcast with
      pauses).
- [ ] A pen, if you printed this.

## Staging

Staging builds and installs the exact build under test. It includes a notarization run and
installs on your devices, so an agent runs it only with you present and only when you say so.
You can run the commands yourself, or tell the agent "stage the risk check" and watch.

All commands run from the release worktree:

```bash
cd ~/git/portview/.worktrees/v1-release-finish
```

### S1. Fix the build identity

```bash
git status --short
```

```bash
git rev-parse --short HEAD
```

```bash
git diff --stat 13aa150..HEAD -- Sources apps Package.swift Makefile
```

```bash
ls apps/Portview.local.xcconfig
```

- The first command must print nothing.
- Write the second command's output in the record block as the source commit.
- The third must print nothing: it shows that the app is still the code reviewed at `13aa150` and
  that every later commit is documentation. If it prints files, stop and tell the lead.
- The fourth must report that there is no such file. That file overrides the signing team, the
  bundle IDs and the version, and this checklist assumes the tracked defaults.

### S2. Build and notarize the Mac app

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make release
```

This replaces whatever is in `build/release`. It ends with a `--- verification ---` block.
Staging continues only if `stapler validate` reports that the validate action worked and `spctl`
reports `accepted` with `source=Notarized Developer ID`. Write down the notarization submission
id that `notarytool` prints.

```bash
shasum -a 256 build/release/export/PortviewHost.app/Contents/MacOS/PortviewHost
```

Write the hash in the record block.

### S3. Install the Mac app, without opening it

Quit Portview Host if it is running (menu-bar icon, then Quit Portview Host). The command below
keeps the app that was installed before as a dated copy under `build/`, then installs the new
one.

```bash
pkill -x PortviewHost; [ -d /Applications/PortviewHost.app ] && mv /Applications/PortviewHost.app "build/PortviewHost-previous-$(date +%Y%m%d-%H%M%S).app"; ditto build/release/export/PortviewHost.app /Applications/PortviewHost.app
```

```bash
spctl -a -vvv /Applications/PortviewHost.app
```

Do not open the app yet. Its first launch is row C3.1.

### S4. Remove Portview's two Mac permissions

C3 checks that both permissions can be granted from the menu-bar popover. This Mac has already
granted them, so they have to be removed first. These two commands affect Portview only.

```bash
tccutil reset ScreenCapture dev.finklea.portview.host
```

```bash
tccutil reset Accessibility dev.finklea.portview.host
```

Until C3.2 and C3.3 grant them again, Portview cannot share the screen or control the Mac.

### S5. Build the iPhone and iPad app

Find the two device identifiers:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl list devices
```

Build the Release client once for each device. The second build is quick. Building for a device
registers it with your developer account if it is not registered yet.

```bash
make generate
```

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build -project apps/PortviewClient/PortviewClient.xcodeproj -scheme PortviewClient -configuration Release -destination 'platform=iOS,id=<IPHONE-ID>' -derivedDataPath build/risk-check-client -allowProvisioningUpdates -allowProvisioningDeviceRegistration
```

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build -project apps/PortviewClient/PortviewClient.xcodeproj -scheme PortviewClient -configuration Release -destination 'platform=iOS,id=<IPAD-ID>' -derivedDataPath build/risk-check-client -allowProvisioningUpdates -allowProvisioningDeviceRegistration
```

### S6. Install on the iPhone and the iPad

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl device install app --device <IPHONE-ID> build/risk-check-client/Build/Products/Release-iphoneos/PortviewClient.app
```

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl device install app --device <IPAD-ID> build/risk-check-client/Build/Products/Release-iphoneos/PortviewClient.app
```

```bash
shasum -a 256 build/risk-check-client/Build/Products/Release-iphoneos/PortviewClient.app/PortviewClient
```

Write the hash in the record block. If a device refuses the install, run that device's build
line from S5 again, install again, and take the hash after the last build.

Installing over an older Portview normally keeps its saved Macs and its settings. Do not open the
app on the iPad yet: its first launch is row C5.1.

### S7. Make the marker file for C3

```bash
M=PV-C3-$(openssl rand -hex 4 | tr a-f A-F); echo "$M" > "$HOME/Desktop/$M.txt"; echo "$M"
```

This puts a small file named after a fresh marker on the Desktop. Write the printed marker in
row C3.7.

### S8. Last things before the sitting

- [ ] Open the Clock app on the Mac and leave its Stopwatch tab ready. C2 uses the running
      stopwatch to make a frozen picture obvious and to time it.
- [ ] Note the Mac's Tailscale address (Tailscale menu, This Device; it starts with `100.`).
- [ ] Unplug the iPhone and the iPad from USB.

### What was and was not verified when this was written (2026-11-27)

- Verified by the agent: the Release client builds for a generic iOS device at head `ceda885` and
  is signed with the team's development profile, with the push and iCloud entitlements, as
  Portview 1.0 (1). `make preflight` was green at this head. There is no
  `apps/Portview.local.xcconfig` on this Mac.
- Not run by the agent: `make release`, the two per-device builds, both installs, and the
  permission reset. The per-device build and install commands are the ones used for the July
  staging, with `-configuration Release` added. Nothing in this checklist has been tried on a
  device.

## Record block

Fill this in once. Every row below is read against it.

| Field | Value |
|---|---|
| Date and start time | |
| Source commit (S1) | |
| App version (iPhone: Portview, Settings, bottom card; expect 1.0 (1)) | |
| Mac app hash (S2), first 12 characters | |
| Notarization submission id (S2) | |
| iPhone and iPad app hash (S6), first 12 characters | |
| Mac model and macOS version | |
| iPhone model and iOS version | |
| iPad model and iPadOS version | |
| iPad keyboard (make and model) | |
| Home network (Wi-Fi name, 5 GHz or 6 GHz, router) | |
| Mac on Wi-Fi or Ethernet | |
| Bluetooth audio device | |

**When a row fails**, write these four things next to it, then go on:
what build (the record block covers it), exactly what you did, exactly what you saw, and whether
reconnecting or reopening the app changed it.

**System prompts.** Fresh installs make macOS and iOS ask their own questions: Local Network and
Screen Recording on the Mac; Local Network, Camera and Notifications on the iPhone and iPad; and
possibly a request to trust the developer in iOS Settings. Allow them and note which appeared.
They are not failures.

**The Quality panel.** In a live session on the iPhone, tap the gauge button in the tool rail. The
panel shows LINK (Mb), FRAME (fps), DECODE (ms) and ENCODE (ms). Once the Mac has played some
audio it also shows a long line that starts with `AUDIO`. "HUD reading" below means: take a
screenshot of the iPhone with the panel open. The screenshot's time stamp and the panel are the
record; you do not need to copy the numbers by hand during the sitting.

**Disconnecting.** The tool rail's exit button (a rectangle with an arrow leaving it, in red) ends
the session and returns to Portview's home screen.

**Pairing.** Pairing a device takes both hands: click Open pairing window on the Mac, scan the QR
on the device, compare the five groups shown on both screens, click Allow on the Mac and approve
with Touch ID. The pairing window closes by itself after two minutes.

## C3 — The Mac app is the menu bar (about 10 minutes, do this first)

Decides whether the menu-bar-only design holds on a real Mac. Pass when each action completes
from the popover, with no main Portview window. System Settings, macOS's own permission alerts,
Touch ID prompts and the file picker are part of the normal flow and do not count against it.

| Row | Do | Pass when | Result | Notes |
|---|---|---|---|---|
| C3.1 | Open `/Applications/PortviewHost.app`. macOS may show its own Screen Recording alert straight away; close it without granting, so the next row tests the popover. | A menu-bar icon appears. No Dock icon, no Portview window. | | |
| C3.2 | Click the menu-bar icon. In the permissions card, click Open Settings beside Screen Recording and allow Portview Host. Then quit Portview Host and open it again from `/Applications`; the grant only takes effect after that. | The card shows Screen Recording as GRANTED. | | |
| C3.3 | In the same card, click Open Settings beside Accessibility and allow Portview Host. Click Re-check if the card has not changed. | The permissions card disappears (it hides once both are granted). | | |
| C3.4 | If the popover shows Start Hosting, click it. On the iPhone, open Portview and connect to the Mac. If it refuses, pair again (see Pairing above). | The iPhone shows the Mac's screen and the pointer moves the Mac. Note whether you had to pair again. | | |
| C3.5 | In the popover, open Settings. If Clipboard sync is already on, turn it off first. Turn it on and approve with Touch ID. | The switch stays on. | | |
| C3.6 | If File transfer is already on, turn it off first. Turn it on and cancel the Touch ID prompt. Then turn it on again and approve. | After the cancel the switch goes back to off and nothing else changes. After the approval it stays on. | | |
| C3.7 | With the iPhone connected, click Send a file in the popover and choose the marker file from the Desktop. Marker: `PV-C3-__________` | The file picker opens in front of other windows. The iPhone shows "Received from your Mac" with the marker as the file name. | | |
| C3.8 | In Settings, if Launch at login is already on, turn it off first. Turn it on. | The switch stays on with no error text. If "Needs approval in System Settings" appears, click Open, approve, and note that it happened. | | |

After C3: the switches from C3.5 and C3.6 stay on for the rest of the sitting.

## C2 — Connecting and a long session (about 20 minutes)

Decides whether the old freeze of 7 to 10 seconds still exists. Pass when there is no video stall
of 3 seconds or more. Start the Clock stopwatch on the Mac and keep it visible on the shared
screen; if the picture freezes, the stopwatch jumps, and the size of the jump is the length of
the stall.

A cold connect means: disconnect, swipe Portview away in the iPhone's app switcher, open it
again, and tap the saved Mac.

| Row | Do | Pass when | Result | Seconds to first picture | Longest stall (s) |
|---|---|---|---|---|---|
| C2.1 | Cold connect 1. Watch the stopwatch for 60 seconds. | Picture appears; no stall of 3 s or more. | | | |
| C2.2 | Cold connect 2. Same. | Same. | | | |
| C2.3 | Cold connect 3. Same, and stay connected. | Same. | | | |
| C2.4 | Use the Mac from the iPhone for 15 minutes: move the pointer, click, scroll, type, zoom, switch apps. Take a HUD reading at the start, near the middle and at the end. | No stall of 3 s or more in the 15 minutes. | | n/a | |

Also note for C2.4: how many stalls of any length you saw, and whether the session dropped or
showed "Reconnecting".

## C1 — Audio (21 minutes; C6 can be done at the Mac meanwhile)

Decides whether the audio work needs more than the clock-drift fix. Pass when the audio plays
for the whole 10 minutes, you hear no click, and the HUD shows no more than 2 gaps per minute.

Stay in the session from C2.4 and start continuous audio on the Mac, with the iPhone's volume up.
If you hear nothing, check the iPhone's volume and that the Mac is playing; the silent switch
does not affect Portview. Audio that stops or never starts is a fail for the row.

How to read gaps: in the `AUDIO` line, `resync` counts every time playback had to restart its
timing, which is what a gap is. The bracket after it names two of the causes, `under` and `gap`.
This checklist uses `resync` as the roadmap's gap count, which is the strict reading. Gaps per
minute is the end value of `resync` minus the start value, divided by 10; for a pass the
difference is 20 or less. The counters go back to zero when a session ends, and may do so when
the audio route changes. If `resync` is lower at the end than at the start, note it and run the
10 minutes again.

| Row | Do | Pass when | Result | Clicks heard | resync start → end |
|---|---|---|---|---|---|
| C1.1 | iPhone speaker. Wait 30 seconds, take a HUD reading, listen for 10 minutes, take a second HUD reading. | Audio throughout. No audible click. `resync` rose by 20 or less. | | | |
| C1.2 | Connect the Bluetooth device to the iPhone and keep the session running. Wait 30 seconds, take a HUD reading, listen for 10 minutes, take a second HUD reading. | Same. | | | |

Also note: anything you heard in the first 30 seconds of either row, whether a click was regular
(about how many seconds apart), whether `drop` in the `AUDIO` line rose, and whether sound and
picture drifted apart by the end.

## C4 — Remote over Tailscale (about 10 minutes)

Decides whether the "remote over your own VPN" claim is true today. Pass when the iPhone connects
from outside your home network and stays controllable for 5 minutes.

The iPhone must already be paired with the Mac from C3.4. Pairing needs you at the Mac, so if
Portview asks to pair during C4, record that as the result.

The app has no Tailscale-specific screen, so getting the address in is part of what this check
measures. Prepare while still on Wi-Fi:

1. On the Mac, click Open pairing window, then Copy pairing URL, then Cancel pairing.
2. Paste the URL into a note. It looks like `portview://pair?host=…&port=…&pin=…&name=…`.
   Replace the value after `host=` with the Mac's Tailscale address. Keep the rest.
3. Get the edited URL onto the iPhone (a synced note, or a message to yourself).

| Row | Do | Pass when | Result | Notes |
|---|---|---|---|---|
| C4.1 | Disconnect the session on the iPhone. Turn Tailscale on, on both devices. Turn the iPhone's Wi-Fi off so it is on mobile data. Swipe Portview away and open it again, so it is on its home screen and has forgotten the home network. | Tailscale shows both devices connected. Portview shows its home screen. | | |
| C4.2 | On the iPhone, copy the edited URL, paste it into Safari's address bar and go. Accept opening Portview, then tap Pair on the prompt at the bottom of Portview's home screen. If that does not work, use "enter IP · pin manually" on the home screen with the Tailscale address, the port and the 64-character pin from the URL. | The Mac's screen appears. Note which way worked and how long it took you. | | |
| C4.3 | Control the Mac for 5 minutes: pointer, clicks, typing, scrolling. Take a HUD reading at the start and at the end. | It stays connected and controllable. Note the lag you feel compared with home Wi-Fi, and any "Reconnecting". | | |

If neither way in C4.2 gets a picture, that is the result: record where it stopped and what the
screen said. Afterwards turn Wi-Fi back on, and note whether the saved Mac still connects at home.

## C5 — iPad with a hardware keyboard (about 15 minutes, observation only)

Decides how big the iPad work is and which keys the network format must carry. There is no pass
or fail here. Write what you see; screenshots are the best record.

| Row | Do | What to write down |
|---|---|---|
| C5.1 | Open Portview on the iPad. If the walkthrough does not appear because Portview was installed before, open it from Settings, Show walkthrough. | Whether the app opened, and what the walkthrough looks like. |
| C5.2 | Look at each screen in portrait and in landscape: walkthrough, home, QR scanner, manual connect, settings, the live session with its tool rail, the Quality panel, and the modifier-key dock that the keyboard button opens. Pair with the Mac along the way (see Pairing above). The connecting screen passes quickly; note it only if you catch it. | For each screen and orientation: fine, stretched, clipped, or broken. Screenshot anything that is not fine. |
| C5.3 | In a live session, open a text editor on the Mac and type on the hardware keyboard: letters, digits, punctuation, Return, Delete, Tab, Escape, the arrow keys. Hold one key down. | Which keys reached the Mac, which did nothing, which did something on the iPad instead. Whether you first had to tap the keyboard button in the tool rail. Whether a held key repeats. |
| C5.4 | Try shortcuts: ⌘C, ⌘V, ⌘A, ⌘Z, ⌘Tab, ⌘Space, ⌘W, ⌘Q, ⌥←, ⇧→, ⌃←. | For each: reached the Mac, kept by iPadOS, or nothing. |
| C5.5 | Keyboard probe build (`portview-w3-probe`), only if it exists by then. Like the rest of staging, it is installed on the iPad only with you present. Follow the steps that come with it. | The probe shows what to record. |

The probe build in C5.5 did not exist when this checklist was written. If it is not ready by
the time of the sitting, C5.1 to C5.4 still go ahead, and the probe becomes a second sitting of
about 10 minutes with the iPad.

## C6 — App Store Connect preparation (about 15 minutes, at the Mac)

Decides whether anything blocks an upload later. These are your account actions; an agent does
not do them. C6.1 passes when the app record exists. The other rows pass when they have an
answer.

| Row | Do | Answer |
|---|---|---|
| C6.1 | In App Store Connect, create the app record: iOS, name "Portview", bundle ID `dev.finklea.portview`. | Record created? Name accepted? If not, what stopped it, or which name did you take? |
| C6.2 | Read Apple's export-compliance questions for the app and decide your answer. The build currently declares `ITSAppUsesNonExemptEncryption = false`; its encryption is the operating system's (QUIC with TLS, and Apple's CryptoKit). | Your answer, and whether it matches what the build declares. |
| C6.3 | Decide where the app is available. | All countries and regions, or which ones are left out and why. |
| C6.4 | Check the trader status that the EU's Digital Services Act asks for (App Store Connect, Business). | Trader or non-trader; verified or pending; which contact details Apple would publish. |

## Summary

| Check | Result (pass, fail, observed) | Failures to file |
|---|---|---|
| C1 audio | | |
| C2 connect and long session | | |
| C3 menu-bar app | | |
| C4 Tailscale | | |
| C5 iPad and keyboard | | |
| C6 App Store Connect | | |

What each result unlocks: C1 and C2 shape the media work (`portview-w6`). A C3 pass is when the
lead asks you to land the release branch on `main` (`portview-own-land`). C4 decides whether the
remote claim needs fixing before it can be advertised. C5 sizes the iPad work and the key list.
C6 tells us about anything that would block the first upload.

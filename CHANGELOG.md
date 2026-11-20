# Changelog

Notable changes to Portview. Format follows [Keep a Changelog](https://keepachangelog.com);
versions follow the app's `MARKETING_VERSION` (`apps/Portview.xcconfig`), not the wire
`ProtocolVersion`.

## [Unreleased] — 1.0.0

First release. Everything below is new.

### Mac host
- Menu-bar-only app: settings (launch at login, preferred port, default display) live in
  the menu-bar popover. The main-window-only panels are retired: throughput/fps/encode
  stats, the activity log (replaced by popover notices), and the remote-input and
  sharing-display cards.
- Clipboard sync and file transfer are opt-in, default off; enabling either from the popover
  requires Touch ID or the Mac password, and disabling applies to connected sessions at once
  (at most one outbound message per connection already in flight can still arrive).
- Menu-bar host: ScreenCaptureKit capture (video + system audio), VideoToolbox low-latency
  HEVC encode, streaming over certificate-pinned QUIC.
- Multi-monitor: pick/switch displays live, hot-plug detection.
- Keep-awake while a client is connected; input injection refused while the screen is locked.
- Notarized Developer ID distribution (`make release`: archive → export → notarize → staple).

### iPhone client
- Metal renderer with in-shader zoom/magnifier, display-rate cursor-follow, trackpad
  gestures, on-screen keyboard with modifiers, clipboard sync, file transfer both ways,
  audio playback, quality HUD, keyboard-aware viewport.
- Bonjour discovery, saved Macs with IP-refresh, automatic reconnect that survives a host
  IP change; optional iCloud re-wake nudge for a backgrounded client.
- First-run walkthrough; camera-denied recovery; `portview://pair` links open a confirm
  prompt before pairing.

### Security
- Mutual authentication: per-device Curve25519 keypairs (iOS Keychain), challenge-response
  bound to the host's pinned certificate, host-side fail-closed pairing store.
- Attended enrollment ceremony: explicit pairing window, dual fingerprint compare, Touch ID.
- QR pairing and 6-digit SAS (commit-then-reveal) pairing, both gated by the pairing window.
- Revocation terminates live sessions immediately; last-device revoke locks the host until
  an in-person re-pair; break-glass "Reset pairing…" (Touch ID-gated) repairs a wedged store.

### Known gaps (see SECURITY.md "Known limitations")
- Paired devices get screen, input, and system audio; clipboard/files are opt-in
  (implemented; hardware verification pending).
- Revoke landing between key-down and key-up can strand one key until the next local input.

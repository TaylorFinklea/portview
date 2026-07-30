# Changelog

Notable changes to Portview. Format follows [Keep a Changelog](https://keepachangelog.com);
versions follow the app's `MARKETING_VERSION` (`apps/Portview.xcconfig`), not the wire
`ProtocolVersion`.

## [Unreleased] — 1.0.0

First release. Everything below is new.

### Mac host
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

### Security
- Mutual authentication: per-device Curve25519 keypairs (iOS Keychain), challenge-response
  bound to the host's pinned certificate, host-side fail-closed pairing store.
- Attended enrollment ceremony: explicit pairing window, dual fingerprint compare, Touch ID.
- QR pairing and 6-digit SAS (commit-then-reveal) pairing, both gated by the pairing window.
- Revocation terminates live sessions immediately; last-device revoke locks the host until
  an in-person re-pair; break-glass "Reset pairing…" (Touch ID-gated) repairs a wedged store.

### Known gaps (see SECURITY.md "Known limitations")
- Paired devices get all capabilities; clipboard/files opt-in is planned.
- Revoke landing between key-down and key-up can strand one key until the next local input.

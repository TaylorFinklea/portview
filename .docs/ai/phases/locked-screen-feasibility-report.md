# Locked-screen / login-window / remote-unlock — feasibility spike

Date: 2026-06-28. Type: time-boxed research spike (no code). Method: 3 parallel web-research agents (capture / privileged-daemon / remote-unlock), each with sources. Triggered by user ask: "make it work on a locked screen, or unlock the screen."

## Bottom line

**Remote UNLOCK: not feasible** for a third-party app. Hard-blocked by design.
**Locked-screen / login-window CAPTURE: technically partial, but not worth building** — fragile, regressed on recent macOS, and cannot be bootstrapped for the actual cold-boot/never-logged-in case. Apple reserves the real capability to itself (private entitlements) + a VNC-only gated entitlement.
**Recommended pivot**: (1) keep-awake power assertion + lock-status in Portview (achievable, real value); (2) Apple's built-in Screen Sharing / Remote Management for the genuine locked/login case; (3) `fdesetup authrestart` / macOS 26 Tahoe pre-login SSH for FileVault reboots.

## Why remote unlock is blocked

- **Secure event input** (`EnableSecureEventInput`) is asserted while a password field / the login window has focus. It drops synthetic `CGEvent` keystrokes from any third-party process before they reach the field — this is the OS anti-keylogger guard. Portview injects via `CGEvent`, so typing the password is impossible.
- **No sanctioned third-party API** to drive `loginwindow` / authenticate / unlock a session (Authorization Services / PAM authorize *operations*, not "dismiss the lock").
- Apple's ARD / Screen Sharing can present + log in at the login window only because `screensharingd` is a **first-party root OS component** wired into WindowServer's privileged input path — not a `CGEvent` tap. Third parties cannot get that path.
- **Touch ID / Apple Watch** unlock are local-only (Secure Enclave / proximity); no remote trigger.
- **FileVault pre-boot** screen is off-network for everything; only Apple's `fdesetup authrestart` (skip once) or macOS 26 Tahoe's new password-only pre-login SSH can clear it.

## Why locked-screen capture isn't worth it

- A root **LaunchDaemon cannot reach the WindowServer** (Mach bootstrap namespace hierarchy — daemons sit above the GUI session). Capture/input must live in a **per-session / LoginWindow LaunchAgent** (`LimitLoadToSessionType = [Aqua, LoginWindow]`, runs as root in that context). So it's a two-component split (root daemon + session agent), à la TeamViewer/AnyDesk.
- Installable today via **SMAppService** (macOS 13+, replaces SMJobBless): helper + plists inside the app bundle, Login-Items approval + admin-auth prompt, Developer-ID signing + Hardened Runtime + **notarization** mandatory.
- **The killer**: Screen Recording is **per-app TCC** and **cannot be granted without a physically-present, logged-in GUI user** clicking Allow once. There is **no way to bootstrap the grant on a Mac that has never had a user log in + approve** — which is exactly the "cold boot, locked, unlock it remotely" scenario the user wants. The grant persists once set, so a pre-login agent can ride a prior grant, but it can't create one.
- Even with all that, **pre-login capture regressed on macOS 15 Sequoia** (CGDisplay/CGDisplayStream/AVCaptureScreenInput/SCK all stopped returning frames pre-login for at least one long-working app), lock-screen capture is commonly **black/broken** on macOS 14–15, and headless Apple Silicon needs a **dummy HDMI dongle** to even materialize a display.
- The macOS 15 `com.apple.developer.persistent-content-capture` entitlement (suppresses re-auth prompts) is **VNC-only and Apple-approval-gated** — not available to a general app.

Net: weeks of work (split daemon/agent, SMAppService, notarization, XPC), high approval friction, version-fragile, and it still **can't do the headline use case** (unlock a cold/locked Mac), because the TCC grant and the unlock path are both walled off.

## Achievable alternative (recommended to build)

- **Keep-awake while connected**: `IOPMAssertion` (`kIOPMAssertionTypePreventUserIdleDisplaySleep` + `…SystemSleep`) held for the life of a client session so the Mac doesn't idle-lock/sleep mid-use. Release on disconnect. (Note: cannot prevent a *manual* lock or a "require password immediately after screensaver" policy lock; only the idle path.)
- **Lock detection / status**: observe `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` (distributed notifications) → tell the client "host is locked — capture paused" instead of a confusing black frame.

## Zero-code alternative for the real locked/login case

- System Settings → General → Sharing → **Screen Sharing** (or Remote Management) → connect with a VNC client → true login-window + lock-screen + remote login, because it's the first-party privileged service. Portview = daily driver; built-in = cold-boot/locked fallback.

## Sources (representative)

- Apple DTS: pre-login capture broke on Sequoia — https://developer.apple.com/forums/thread/768146 ; daemon can't talk to WindowServer, use a pre-login agent — https://developer.apple.com/forums/thread/45536
- `persistent-content-capture` (VNC-only) — https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.persistent-content-capture ; Hockenberry "private entitlements" — https://mjtsai.com/blog/2024/08/08/sequoia-screen-recording-prompts-and-the-persistent-content-capture-entitlement/
- SMAppService daemon install — https://theevilbit.github.io/posts/smappservice/ ; LimitLoadToSessionType=LoginWindow runs as root (eskimo) — https://developer.apple.com/forums/thread/696859 ; TCC "responsible code" needs an app bundle — https://developer.apple.com/forums/thread/694948
- Secure event input blocks injection — https://espanso.org/docs/troubleshooting/secure-input/ ; ARD lock/unlock is first-party — https://support.apple.com/guide/remote-desktop/lock-or-unlock-a-screen-apd37d6089c/mac ; FileVault remote + Tahoe SSH — https://www.jeffgeerling.com/blog/2025/you-can-finally-manage-macs-filevault-remotely-tahoe/

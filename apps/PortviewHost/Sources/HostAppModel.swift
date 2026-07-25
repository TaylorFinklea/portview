// SPDX-License-Identifier: Apache-2.0
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import LocalAuthentication
import Observation
import PortviewHostCore
import PortviewProtocol
import PortviewTransport

/// One paired-device row for the menu-bar "Paired devices" surface (design §1a step 1). The
/// `fingerprint` is precomputed in `HostAppModel` (via `KeyFingerprint.short`) so the view stays a
/// pure `PortviewHostCore` consumer and never imports `PortviewProtocol` or touches the raw
/// `publicKey` — fingerprint only, never the key bytes.
struct PairedDeviceRow: Identifiable, Equatable {
    let id: String
    let name: String
    let fingerprint: String
    let lastSeen: Date
}

@MainActor
@Observable
final class HostAppModel {
    enum State: Equatable {
        case idle
        case starting
        case ready(HostReadyDetails)
        case failed(String)

        var title: String {
            switch self {
            case .idle: "Idle"
            case .starting: "Starting host..."
            case .ready: "Host ready"
            case .failed: "Host failed"
            }
        }
    }

    private static let displayName = "Portview Host"

    var state: State = .idle
    var accessibilityWarning: String?
    var messages: [String] = []
    /// Live connected-device session state (count, primary device name, latest telemetry).
    private(set) var sessions = HostSessions()
    /// When the current client session began (for the "connected mm:ss" readout); nil when none.
    private(set) var connectedSince: Date?
    /// Real, polled permission status (not inferred from run state) — drives guided onboarding.
    private(set) var screenRecordingGranted = false
    private(set) var accessibilityGranted = false

    /// Guided onboarding derived from the live permission bools.
    var onboarding: PermissionsOnboarding {
        PermissionsOnboarding(screenRecordingGranted: screenRecordingGranted, accessibilityGranted: accessibilityGranted)
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let control = HostControl()
    /// The ONE shared durable pairing store (design §2/§6c). Built once here — NOT per-`start()` — so
    /// the serve loop authorizes against, and the revoke UI mutates, the SAME actor instance: the
    /// in-process live invalidation on revoke (`control.beginRevoke`) is then synchronous with the
    /// durable removal (`pairings.revoke`). Passed into `events(...)` in `start()` and read by
    /// `refreshEnrolledDevices()` / `revoke(_:)`.
    @ObservationIgnored private let pairings = PairingStore()
    @ObservationIgnored private let sasControl = SASPairingControl()
    /// Chains every `beginPairing`/`endPairing` window transition into one ordered sequence.
    /// Both methods fire their actor calls from unstructured `Task`s; without this, a rapid
    /// begin→end (or end→begin) pair can be scheduled out of call order, leaving the SAS
    /// window/authority epoch open while the UI shows closed. Each call awaits the previous
    /// task's `.value` before running its own actor calls, so transitions always land in the
    /// order they were invoked, regardless of scheduler timing.
    @ObservationIgnored private var windowTransition: Task<Void, Never>?
    /// The ONE shared enrollment-ceremony authority (han.3 design) — constructed once here (not
    /// per-`start()`) so `beginPairing`/`endPairing` and the Allow/Deny actions all resolve against
    /// the same actor state; passed into `events(...)` below beside the app's `PairingStore`.
    @ObservationIgnored private let authority = EnrollmentAuthority()
    @ObservationIgnored private var permissionsTask: Task<Void, Never>?
    @ObservationIgnored private var pairingTimeoutTask: Task<Void, Never>?
    /// CloudKit re-wake beacon (fire-and-forget; each trigger runs in its own task so an iCloud stall
    /// can never touch hosting). Writes only on explicit triggers — hosting ready + the menu-bar
    /// "Ask iPhone to reconnect" nudge — never on a timer.
    @ObservationIgnored private let beaconWriter = HostBeaconWriter(store: CloudKitBeaconStore())

    /// True while a user-opened SAS pairing window is live (gates the preamble + the displayed code).
    private(set) var isPairing = false
    /// The 6-digit SAS code to show the user (never logged); nil unless a preamble derived one.
    private(set) var displayedSASCode: String?
    /// Transient "✓ a client confirmed" signal (Guardrail E). Does NOT close the window — the window
    /// closes only via a CORRELATED `.enrollmentResolved(approved: true)` (review Finding E — see
    /// `handle(_:)`), the timeout, the cap, or stop.
    private(set) var clientConfirmed = false
    /// The current pairing window's epoch lease (nil when no window is open). Set from
    /// `SASPairingControl.openWindow()`'s return inside the serialized `windowTransition`; cleared in
    /// `endPairing()`. A `.sasCode`/`.sasConfirmed` is applied to the HUD only when its stamped lease
    /// equals this, so a prior window's async emit can never mutate a newer window's HUD.
    private(set) var currentWindowLease: WindowLease?
    /// Monotonic epoch bumped SYNCHRONOUSLY on every window transition (`beginPairing`/`endPairing`).
    /// `beginPairing`'s deferred `currentWindowLease` write (which lands only after two `await`s inside
    /// the serialized `windowTransition`) commits ONLY if this epoch is still the one it captured at
    /// call time — otherwise a delayed resume of a superseded begin could write a stale window's lease
    /// back over a newer window's, re-opening the exact stale-lease-matches-newer-HUD hole the lease
    /// exists to close (task-9 review Important). The synchronous clear/bump makes the async set as
    /// authoritative as the sync clear.
    @ObservationIgnored private var windowEpoch: UInt64 = 0
    /// How long a pairing window stays open before auto-closing.
    private static let pairingWindowSeconds: TimeInterval = 120

    /// The single in-flight enrollment prompt (han.3), or nil when none is pending. Set by
    /// `.enrollmentRequest`, cleared by `.enrollmentResolved` — the L1 no-false-success path: a
    /// prompt must never outlive the request it was raised for.
    private(set) var enrollmentPrompt: (attemptID: UUID, fingerprint: String, claimedName: String, expiresAt: Date)?
    /// Per-attempt enrollment-decision tokens (replaces the old global `enrollmentDecisionInFlight`
    /// + `approvalInFlightID`). Each Allow/Deny tap mints a token keyed by attemptID; a second tap for
    /// an attempt already authenticating is rejected (no second LAContext), and each task's `defer`
    /// clears only its own token. Observed (not @ObservationIgnored) so the popover's per-attempt
    /// button-disable re-renders when it mutates.
    private var decisions = DecisionTokenRegistry()

    /// Per-attempt gate for the Allow/Deny buttons — true while THIS attempt's decision is
    /// authenticating (LAContext running), so a double-tap can't launch a second LAContext.
    func enrollmentDecisionInFlight(for attemptID: UUID) -> Bool { decisions.isInFlight(attemptID) }

    /// The enrolled devices shown on the menu-bar "Paired devices" surface (design §1a step 1),
    /// snapshotted from `pairings.list()`. Refreshed when the surface opens (view `.task`), after a
    /// successful enroll (`.enrollmentResolved(approved: true)`), and after a revoke/retry/cancel.
    private(set) var enrolledDevices: [PairedDeviceRow] = []

    /// Devices whose durable revoke THREW *in this process* (design §1a step 5, fail closed): id → the
    /// retained `RevokeLease`. The in-process fence stays set (K unauthorizable) until a successful
    /// Retry or an authenticated Cancel lifts it.
    private(set) var revokeFailures: [String: RevokeLease] = [:]

    /// Devices whose revoke is DURABLY recorded but not durably completed, read from
    /// `pairings.pendingRevocations()` (design §6d, Sol review I5). This is the half that survives a
    /// process restart: `control`'s fence and `revokeFailures` above are in-memory only, so after a
    /// quit/crash the incomplete state — and the fail-closed denial that goes with it — comes from the
    /// durable intent item instead. A row in EITHER collection renders Retry / Cancel (see
    /// `revokeIncomplete`).
    private(set) var pendingRevocations: Set<String> = []

    /// Devices whose revoke could not be recorded DURABLY AT ALL — `PairingStore.revoke` threw
    /// `RevokeIncomplete.notDurable`, meaning neither the removal nor the revocation intent landed
    /// (the correlated one-keychain failure). These rows are NOT the same as `pendingRevocations`:
    /// the only thing denying the device is this process's in-memory `HostControl` fence, so quitting
    /// or crashing Portview RE-ADMITS it. The row and its copy must say that out loud (design §1a
    /// step 5, §7 invariant 6b) — a silent "revoke incomplete" here would be the same false-assurance
    /// bug the durable intent was introduced to fix.
    private(set) var nonDurableRevokes: Set<String> = []

    /// True when the intent item itself could not be read on the last refresh. Authorization fails
    /// CLOSED on that read (`PairingStore.authorizedMap`), so every device is currently denied while
    /// the paired list still renders — the surface must say the pairing store is unreadable rather
    /// than show a clean, reassuring list (`PendingRevocations.unreadable`).
    private(set) var pairingStoreUnreadable = false

    /// True when this device's revoke is incomplete and the row must offer Retry / Cancel instead of
    /// Revoke: this process holds the retained lease, a durable intent survived a restart, or the
    /// revoke could not be recorded durably at all.
    func revokeIncomplete(_ id: String) -> Bool {
        revokeFailures[id] != nil || pendingRevocations.contains(id) || nonDurableRevokes.contains(id)
    }

    /// True when this device's incomplete revoke is NOT durable — the row must warn that the device
    /// regains access if Portview restarts, instead of the plain "revoke incomplete" copy.
    func revokeNotDurable(_ id: String) -> Bool { nonDurableRevokes.contains(id) }

    /// True when the host has been through enrollment but now has ZERO paired devices — the
    /// last-device lockout (product decision 2): Portview accepts no one until an in-person re-pair.
    /// Derived from the DURABLE `enrollmentSnapshot()` in `refreshEnrolledDevices` (NOT bare
    /// `enrolledDevices.isEmpty`, which is also true on a fresh never-enrolled install), so it survives
    /// an app restart and drives the menu-bar locked-out banner in the surface where revoke happens.
    private(set) var lockedOut = false
    /// Device ids with a revoke/retry/cancel op in flight — a reentrancy guard so a rapid double-tap
    /// can't launch a second `LAContext` prompt for the same device (mirrors the enrollment Allow/Deny
    /// `DecisionTokenRegistry.beginIfIdle` guard). Cleared in each op's `defer`, covering every exit.
    @ObservationIgnored private var revokeInFlight: Set<String> = []

    /// Reload `enrolledDevices` from the shared `pairings` store, precomputing each row's compare
    /// fingerprint here so the view never imports `PortviewProtocol` or sees the raw `publicKey`.
    func refreshEnrolledDevices() async {
        let list = await pairings.list()
        enrolledDevices = list
            .map { PairedDeviceRow(id: $0.id, name: $0.deviceName,
                                   fingerprint: KeyFingerprint.short(forPublicKey: $0.publicKey),
                                   lastSeen: $0.lastSeen) }
            .sorted { $0.lastSeen > $1.lastSeen }
        // Durable incomplete-revoke state (§6d): read on EVERY refresh — including the first one after
        // launch — so a revoke wedged in a previous process still surfaces Retry / Cancel on its row.
        // `list()` deliberately still contains those devices (they remain enrolled, just unauthorizable).
        await refreshPendingRevocations()
        // Locked-out (decision 2): distinguish enrolled-then-emptied from a fresh never-enrolled
        // install. `.populated` = migration completed (a device was enrolled at some point), so zero
        // devices now is the in-person-re-pair lockout; `.empty`/`.unreadable` → no banner. Only hit
        // the durable snapshot when the set is actually empty (`await` can't ride an `&&` autoclosure).
        if enrolledDevices.isEmpty {
            lockedOut = await pairings.enrollmentSnapshot() == .populated
        } else {
            lockedOut = false
        }
    }

    /// Re-read the durable revocation-intent view. `.unreadable` is NOT folded into an empty set: on
    /// that read `PairingStore` denies every device, so replacing `pendingRevocations` with `[]` would
    /// silently drop every incomplete-revoke row (and its Retry / Cancel) at the moment nothing is
    /// authorized. Keep the last known set and raise `pairingStoreUnreadable` so the surface says so.
    private func refreshPendingRevocations() async {
        switch await pairings.pendingRevocations() {
        case .known(let ids):
            pendingRevocations = ids
            pairingStoreUnreadable = false
        case .unreadable:
            pairingStoreUnreadable = true
        }
    }

    /// The display name for a device id, for user-facing copy; falls back to a generic noun when the
    /// row is not in the current snapshot.
    private func deviceName(_ id: String) -> String {
        enrolledDevices.first { $0.id == id }?.name ?? "That device"
    }

    /// Revoke a paired device (design §1a steps 2–6). The confirmation dialog (product decision 1)
    /// is presented by the view BEFORE this is called; here we run the mandatory `LAContext` gate —
    /// an ungated Revoke is remotely clickable via an injected CGEvent with zero local presence, the
    /// exact hole the enrollment Allow/Deny gate closes — and only a POSITIVE result proceeds. Then
    /// the lease-owned sequence: `beginRevoke` (synchronous live fence + kill, step 3) → durable
    /// `pairings.revoke` (step 4) → on success `endRevoke` + refresh (steps 5–6); on a durable
    /// FAILURE do NOT `endRevoke` — keep the fence (fail closed) and retain the lease so the row can
    /// offer Retry / an LAContext-gated Cancel.
    func revoke(_ id: String) {
        guard !revokeInFlight.contains(id) else { return }  // reentrancy: no second LAContext for this id
        revokeInFlight.insert(id)
        Task {
            defer { self.revokeInFlight.remove(id) }
            let context = LAContext()
            let approved = (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                              localizedReason: "Revoke this device's access to this Mac")) ?? false
            guard approved else { return }
            let receipt = self.control.beginRevoke(clientKeyID: id)  // step 3: live fence + kill (sync)
            do {
                try await self.pairings.revoke(id: id)               // step 4: durable removal
                self.control.endRevoke(lease: receipt.lease)         // step 5: finalize on success
                self.revokeFailures[id] = nil
                self.nonDurableRevokes.remove(id)
                await self.refreshEnrolledDevices()                  // step 6: revoked row disappears
                self.noteLastDeviceIfEmpty()
            } catch {
                // Durable write threw: do NOT endRevoke — the fence stays and K is unauthorizable
                // (fail closed, H-c). Retain the lease so the row surfaces Retry / an authenticated
                // Cancel. `enrolledDevices` is left un-refreshed, so the row stays visible.
                self.revokeFailures[id] = receipt.lease
                // Pick up the DURABLE intent `pairings.revoke` recorded before it attempted the
                // removal (§6d): that is what keeps this row incomplete — and K denied — if the app
                // never gets a Retry/Cancel and is quit or crashes before one lands.
                await self.refreshPendingRevocations()
                self.noteRevokeDurability(id, error: error)
            }
        }
    }

    /// Retry a durable revoke that previously threw (design §1a step 5), re-running the durable
    /// removal. On success, lift the fence and drop the row; on a repeated failure, keep the fence +
    /// lease so the row stays "incomplete".
    ///
    /// Works with OR without an in-process lease (§6d, Sol review I5). Same process: the retained
    /// lease is still here, and a successful removal finalizes it through `endRevoke` exactly as
    /// before (matching-lease semantics unchanged). After a RESTART there is no lease to reuse — the
    /// row came from the durable intent — so this re-attempts the durable removal alone; there is no
    /// fence to lift in a fresh process, and `pairings.revoke` clears the intent on success.
    func retryRevoke(_ id: String) {
        guard revokeIncomplete(id), !revokeInFlight.contains(id) else { return }
        revokeInFlight.insert(id)
        Task {
            defer { self.revokeInFlight.remove(id) }
            do {
                try await self.pairings.revoke(id: id)
                if let lease = self.revokeFailures[id] { self.control.endRevoke(lease: lease) }
                self.revokeFailures[id] = nil
                self.nonDurableRevokes.remove(id)
                await self.refreshEnrolledDevices()  // also refreshes `pendingRevocations`
                self.noteLastDeviceIfEmpty()
            } catch {
                // Still failing — keep the fence + lease; the row remains in the Retry/Cancel state.
                // But re-read the durability of the fence: `pairings.revoke` re-attempts the INTENT
                // write on every call, so a Retry after a transient keychain failure can promote a
                // not-durable revoke into a durably-fenced one even while the removal keeps failing.
                // That promotion has to reach the row, or the user is left staring at a stale "this
                // device regains access if Portview restarts" warning that is no longer true.
                await self.refreshPendingRevocations()
                self.noteRevokeDurability(id, error: error)
            }
        }
    }

    /// Classify a failed durable revoke and tell the user the TRUTH about which fence they have
    /// (Sol re-review I5 follow-up). `.fencedDurably` = denied across a restart, retry at leisure.
    /// `.notDurable` = nothing durable was recorded, so only this process is holding the device out
    /// and a quit/crash re-admits it — that must never render as a quiet "revoke incomplete". Any
    /// other error type is treated as not-durable: unclassified means unproven, and the safe lie to
    /// avoid is the reassuring one.
    private func noteRevokeDurability(_ id: String, error: any Error) {
        let durablyFenced = (error as? RevokeIncomplete)?.isDurablyFenced ?? false
        if durablyFenced {
            // Promotion (Retry recorded the intent this time): drop the warning and say so once.
            if nonDurableRevokes.remove(id) != nil {
                messages.append("\(deviceName(id)) is now blocked even if Portview restarts, but the revoke still hasn't finished — keep retrying.")
            }
        } else if nonDurableRevokes.insert(id).inserted {
            messages.append("Couldn't record that revoke — \(deviceName(id)) is blocked right now, but it REGAINS ACCESS if Portview restarts. Retry until this warning clears.")
        }
    }

    /// Cancel a wedged revoke (design §1a step 5): the LAContext-gated escape hatch that lifts the
    /// fence WITHOUT a durable revoke, deliberately re-admitting the still-enrolled device (the owner
    /// accepts the risk for a permanently-locked keychain). Only a POSITIVE LAContext result proceeds.
    ///
    /// Two fences must come down and the DURABLE one goes first (§6d, Sol review I5): the recorded
    /// revocation intent (which survives a restart and denies K on its own) and — only when this
    /// process still holds it — the in-process `RevokeLease` fence. If the durable clear throws we
    /// return with BOTH still in place: a Cancel that cannot be made durable must fail closed, not
    /// half-re-admit a device that the next launch would deny again anyway.
    func cancelRevoke(_ id: String) {
        guard revokeIncomplete(id), !revokeInFlight.contains(id) else { return }
        revokeInFlight.insert(id)
        Task {
            defer { self.revokeInFlight.remove(id) }
            let context = LAContext()
            let approved = (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                              localizedReason: "Confirm you're at this Mac to re-admit this device")) ?? false
            guard approved else { return }
            do {
                try await self.pairings.cancelRevocationIntent(id: id)
            } catch {
                self.messages.append("Couldn't re-admit that device — the keychain is unavailable. It stays revoked; try again.")
                return
            }
            if let lease = self.revokeFailures[id] {
                self.control.cancelRevoke(lease: lease)  // lift fence WITHOUT durable revoke: re-admit K
            }
            self.revokeFailures[id] = nil
            // The device is deliberately re-admitted, so the not-durable warning is spent: there is no
            // longer a revoke whose durability could be misreported.
            self.nonDurableRevokes.remove(id)
            await self.refreshEnrolledDevices()       // the still-enrolled device reappears in the list
        }
    }

    /// Last-device copy (product decision 2): if a successful revoke emptied the paired set, tell the
    /// user the host is now locked out. The host stays `.required` (revoke never clears
    /// `migrationComplete`); bootstrap never reopens — there is no remote self-recovery.
    private func noteLastDeviceIfEmpty() {
        if enrolledDevices.isEmpty {
            messages.append("That was your last paired device. Portview now accepts no one until you re-pair in person.")
        }
    }

    /// Observed (not derived from the @ObservationIgnored task) so the menu-bar glyph + Start/Stop
    /// re-render on EVERY transition — including when the serve loop ends on its own while ready.
    private(set) var isRunning = false
    var screenRecordingHelp: String { HostRunner.screenRecordingHelp(for: .app(displayName: Self.displayName)) }

    /// Menu-bar glyph reflecting state at a glance (reads observed state + sessions → auto-updates).
    var menuBarSymbol: String {
        let failed: Bool = if case .failed = state { true } else { false }
        return HostMenuBar.symbol(isFailed: failed, isRunning: isRunning, connectedCount: sessions.count)
    }

    func start() {
        guard task == nil else { return }
        isRunning = true
        state = .starting
        accessibilityWarning = nil
        messages = []
        sessions = HostSessions()
        connectedSince = nil

        task = Task { [weak self, control, sasControl, authority, pairings] in
            // Legacy-bootstrap until first-enroll auto-promotion flips this host to `.required`
            // (han.3 revisits the open-ended expiry). `pairings` is the ONE shared PairingStore
            // (stored property) — han.4's revoke UI mutates this SAME instance, so the serve loop
            // authorizes against exactly the store revoke removes from. `authority` is likewise the
            // ONE shared EnrollmentAuthority (see its stored property comment above).
            let events = HostRunner().events(identity: .app(displayName: Self.displayName), control: control, sasControl: sasControl,
                                             authPolicy: .legacyBootstrap(expiresAt: .distantFuture),
                                             pairings: pairings,
                                             enrollment: authority)
            for await event in events {
                self?.handle(event)
            }
            guard let self else { return }
            self.task = nil
            self.isRunning = false
            if self.state == .starting {
                self.state = .idle
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        state = .idle
        sessions = HostSessions()
        connectedSince = nil
        // Sol#3a: a stale, actionable enrollment prompt must not survive hosting stopping — clear it
        // (and the in-flight/authenticating decision tokens that gate its buttons) alongside the
        // pairing window. Clearing the whole registry is fine here — hosting is ending.
        enrollmentPrompt = nil
        decisions = DecisionTokenRegistry()
        endPairing()
    }

    /// User opened a pairing window: clients may now run the SAS preamble and the host will display a
    /// code. Auto-closes after `pairingWindowSeconds` so an idle code can't linger.
    ///
    /// Legacy barrier (design v2, review H3/Sol-1): evict every legacy-admitted session and reset the
    /// enrollment authority's epoch BEFORE the SAS window opens — no remote peer can be mid-session
    /// (able to watch the ceremony or click Deny) once pairing UI becomes reachable.
    func beginPairing() {
        guard isRunning else { return }
        control.evictLegacyAdmitted()
        windowEpoch += 1
        let epoch = windowEpoch
        windowTransition = Task { [weak self, authority, sasControl, previous = windowTransition] in
            await previous?.value
            await authority.windowOpened()
            let lease = await sasControl.openWindow()
            // Back on the main actor after the awaits: record the epoch this transition minted, so
            // `handle(_:)` can bind `.sasCode`/`.sasConfirmed` to it — but ONLY if no later
            // begin/end superseded us (each bumps `windowEpoch` synchronously). A stale commit here
            // would let a prior window's lease match a newer window's HUD.
            guard let self, self.windowEpoch == epoch else { return }
            self.currentWindowLease = lease
        }
        isPairing = true
        displayedSASCode = nil
        clientConfirmed = false
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pairingWindowSeconds))
            guard let self, !Task.isCancelled else { return }
            self.endPairing()
        }
    }

    /// Close the pairing window and clear the displayed code (manual cancel / timeout / connect / stop).
    func endPairing() {
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        windowEpoch += 1  // supersede any pending begin's deferred `currentWindowLease` commit
        windowTransition = Task { [authority, sasControl, previous = windowTransition] in
            await previous?.value
            await sasControl.closeWindow()
            await authority.windowClosed()
        }
        isPairing = false
        displayedSASCode = nil
        clientConfirmed = false
        currentWindowLease = nil
    }

    /// Allow: gates every approval behind genuine LOCAL presence — LAContext is evaluated fresh per
    /// tap, and only a POSITIVE result reaches `authority.approve`. Failure or cancel leaves the
    /// prompt exactly as-is (no false success); it clears only via `.enrollmentResolved` (approve,
    /// deny, the ceremony's internal deadline, or window close).
    ///
    /// L1 also requires the inverse never be silent: if the request resolves/expires WHILE the user
    /// is mid-authentication, a LAContext success arriving afterward must not quietly no-op. The
    /// attemptID is captured at tap; after LAContext succeeds we re-check `enrollmentPrompt` still
    /// matches it before calling `approve` — a mismatch means it resolved out from under us, so we
    /// tell the user instead of dropping the approval on the floor. This attempt's approval token
    /// (`decisions.hasApprovalInFlight`) lets `handle(_:)` raise that same message immediately if the
    /// resolution lands while LAContext is still running (rather than only once/if LAContext ever
    /// returns), and coordinates with the mismatch branch here so the message shows exactly once.
    func approveEnrollment(_ attemptID: UUID) {
        // Reject a duplicate start for an attempt already authenticating — no second LAContext.
        guard let token = decisions.beginIfIdle(attemptID: attemptID, isApproval: true) else { return }
        Task { [authority] in
            defer { self.decisions.clear(attemptID: attemptID, ifToken: token) }
            let context = LAContext()
            let approved = (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                               localizedReason: "Approve pairing this device")) ?? false
            guard approved else { return }
            guard self.enrollmentPrompt?.attemptID == attemptID else {
                if self.decisions.hasApprovalInFlight(attemptID) {
                    self.messages.append("That pairing request expired before approval completed — reopen pairing and try again.")
                }
                return
            }
            await authority.approve(attemptID)
        }
    }

    /// Deny: gated behind the SAME local-presence check as Allow (review Finding GLM2). Evicting
    /// legacy-admitted sessions at `beginPairing()` does not remove an AUTHENTICATED streaming peer —
    /// it stays connected for the whole ceremony, can see the prompt on the shared screen, and
    /// (before this fix) could inject a CGEvent click on Deny with zero local presence, since only
    /// Allow was LAContext-gated. Requiring the same positive LAContext result here closes that gap:
    /// a remote click on either button now does nothing without someone physically at the Mac.
    /// Failure or cancel leaves the prompt exactly as-is (no false action) — a stale/expired
    /// `attemptID` is a safe no-op on the actor side (`EnrollmentAuthority.deny`) regardless.
    func denyEnrollment(_ attemptID: UUID) {
        // Reject a duplicate start for an attempt already authenticating — no second LAContext.
        guard let token = decisions.beginIfIdle(attemptID: attemptID, isApproval: false) else { return }
        Task { [authority] in
            defer { self.decisions.clear(attemptID: attemptID, ifToken: token) }
            let context = LAContext()
            let confirmed = (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                                localizedReason: "Confirm you're at this Mac to dismiss the pairing request")) ?? false
            guard confirmed else { return }
            await authority.deny(attemptID)
        }
    }

    /// Close the connected client session(s) without stopping hosting (keeps advertising).
    func disconnectClients() {
        control.disconnectAll()
    }

    /// The nudge is only offered when it can actually reach iCloud: the process carries the
    /// CloudKit entitlement (default dev builds don't — `PORTVIEW_HOST_ENTITLEMENTS` is opt-in)
    /// AND hosting reached `.ready` (before that the writer has no identity and drops the write).
    /// Gating here keeps the fail-soft rule honest: no success message for a write that never
    /// happened.
    var canAskReconnect: Bool {
        guard case .ready = state else { return false }
        return CloudKitBeaconStore.isAvailable
    }

    /// Menu-bar nudge: write a `wantsReconnect` beacon so the paired iPhone gets a silent push and
    /// offers tap-to-resume. Only meaningful once ready (the menu row is hidden otherwise).
    func askIPhoneToReconnect() {
        guard canAskReconnect else { return }
        let writer = beaconWriter
        Task { await writer.requestReconnect() }
        messages.append("asked iPhone to reconnect (via iCloud)")
    }

    /// Pick a file and send it to the connected iPhone (Mac→iPhone transfer).
    func sendFileToClient() {
        guard let target = sessions.devices.first?.id else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else {
            messages.append("couldn't read \(url.lastPathComponent)")
            return
        }
        control.sendFile(name: url.lastPathComponent, data: data, to: target)
        messages.append("sending \(url.lastPathComponent) → iPhone")
    }

    func copyPairingURL() {
        guard case .ready(let details) = state else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(details.pairingURL, forType: .string)
    }

    func openScreenRecordingSettings() {
        openPrivacyPane(anchor: "Privacy_ScreenCapture")
    }

    func openAccessibilitySettings() {
        openPrivacyPane(anchor: "Privacy_Accessibility")
    }

    /// Read the CURRENT permission status without prompting (the prompt is owned once by HostRunner).
    func refreshPermissions() {
        let screenRecording = CGPreflightScreenCaptureAccess()
        let accessibility = AXIsProcessTrusted()
        if screenRecording != screenRecordingGranted { screenRecordingGranted = screenRecording }
        if accessibility != accessibilityGranted { accessibilityGranted = accessibility }
    }

    /// Poll permission status every 2s (idempotent; runs for the app's lifetime once started, NOT
    /// tied to the window — hosting and the menu bar outlive the window, so monitoring must too).
    /// Accessibility flips live; Screen Recording shows granted only after relaunch (onboarding copy
    /// says so). An immediate refresh on each call keeps a freshly-shown surface accurate.
    func startPermissionMonitoring() {
        refreshPermissions()
        guard permissionsTask == nil else { return }
        permissionsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.refreshPermissions()
            }
        }
    }

    private func handle(_ event: HostRunnerEvent) {
        switch event {
        case .ready(let details):
            state = .ready(details)
            // Hosting-start beacon trigger. This also subsumes the spec's port-change trigger: the
            // persisted port can only change at a listener (re)bind, and every bind path re-emits
            // `.ready` carrying the actual bound port — if a future change lets the port move
            // MID-RUN, wire `beaconWriter.portChanged(_:)` there. Reuses the pin fingerprint hex
            // the runner computed for the pairing payload as the record name. Own task: a CloudKit
            // outage must never block event handling or the serve path.
            let writer = beaconWriter
            Task {
                await writer.hostingStarted(pinHex: details.pinHex, hostName: details.serviceName,
                                            port: details.port)
            }
        case .message(let message):
            messages.append(message)
        case .accessibilityWarning(let warning):
            accessibilityWarning = warning
        case .failed(let message):
            state = .failed(message)
            messages.append(message)
        case .sasCode(let code, let lease):
            // Bind to the CURRENT window epoch: the emit hops to the main actor and a newer window may
            // have opened in that gap; `isPairing` alone can't tell an old window's code from a new
            // one's, so gate on the lease matching. Acceptable reverse race: a valid NEW-window code
            // arriving a beat before `windowTransition` sets `currentWindowLease` is dropped (the
            // client retries) — the security direction, ignoring a STALE-old lease, holds regardless.
            if isPairing, lease == currentWindowLease { displayedSASCode = code }  // shown on the HUD; never logged
        case .sasConfirmed(let lease):
            // Positive signal only — do NOT close the shared window (a relayed confirm from any peer
            // must not be able to close it). The window closes via a correlated
            // `.enrollmentResolved(approved: true)`, the timeout, the cap, or stop (Finding E). Same
            // window-epoch gate as `.sasCode`: a prior window's confirm can't flip a newer HUD.
            if isPairing, lease == currentWindowLease { clientConfirmed = true }
        case .deviceConnected, .deviceDisconnected, .sessionStats:
            // Review Finding E: this branch used to call `endPairing()` on ANY `.deviceConnected` —
            // but that event also fires for an already-enrolled device merely RECONNECTING (e.g.
            // re-wake) during a second-device enrollment, which would close the window and invalidate
            // an unrelated pending enrollment request out from under it. The window now closes only
            // on the CORRELATED `.enrollmentResolved(approved: true)` below; `.deviceConnected` here
            // is session tracking only. A re-pairing already-enrolled device produces no enrollment
            // event, so its window closes on the 120s timeout instead — acceptable per the review.
            let wasConnected = sessions.count > 0
            sessions.apply(event)
            let nowConnected = sessions.count > 0
            if nowConnected, !wasConnected { connectedSince = Date() }
            if !nowConnected { connectedSince = nil }
            if case .deviceConnected(_, let name) = event {
                messages.append("device connected · \(name)")
            }
            if case .deviceDisconnected = event { messages.append("device disconnected") }
        case .enrollmentRequest(let attemptID, let fingerprint, let claimedName, let expiresAt):
            enrollmentPrompt = (attemptID: attemptID, fingerprint: fingerprint, claimedName: claimedName, expiresAt: expiresAt)
        case .enrollmentResolved(let attemptID, let approved):
            // Only clear if this resolution is for the prompt currently shown — a prompt must
            // never outlive its own request (L1 no-false-success path). Sol#3b: clear this attempt's
            // decision token alongside it (not only at the end of an approve/deny call). Captured
            // before any clear so the not-approved check below still sees the in-flight approval.
            let wasShownPrompt = (enrollmentPrompt?.attemptID == attemptID)
            let approvalWasInFlight = decisions.hasApprovalInFlight(attemptID)
            if wasShownPrompt {
                enrollmentPrompt = nil
                // Narrowed correlated-clear: clear only THIS resolved attemptID's decision entry (the
                // per-task token model already keeps a later prompt's buttons — a different attemptID
                // — independent, so this is cleanup for the resolved attempt, not a global reset).
                decisions.clear(attemptID: attemptID)
            }
            // The correlated close (Finding E, tightened per review Important #1): an APPROVED
            // enrollment ends the pairing ceremony only when it's the attempt that was actually on
            // screen. `EnrollmentAuthority.pending` clears synchronously the instant `approve()` is
            // called — well before `runEnrollmentCeremony` finishes the keychain enroll and emits
            // this event — so a second unknown device can `begin()` its own attempt in that gap. A
            // late `.enrollmentResolved(approved: true)` for the FIRST attempt must not close the
            // window on that second, unrelated, still-pending enrollment.
            if approved && wasShownPrompt { endPairing() }
            // A successful enroll added a device to the durable set — refresh the Paired-devices
            // surface so the new row is present the next time it opens (§1a step 1 refresh point).
            if approved { Task { await self.refreshEnrolledDevices() } }
            // If this resolved-not-approved WHILE an Allow tap's LAContext is still running for the
            // same attemptID, tell the user now rather than leaving them in silence until (or
            // unless) LAContext ever returns. Clears this attempt's decision entry too (so the still-
            // running approve task's mismatch branch won't double-message) even when a NEWER prompt
            // has since replaced this one — that newer prompt's buttons key off its own attemptID.
            if !approved, approvalWasInFlight {
                decisions.clear(attemptID: attemptID)
                messages.append("That pairing request expired before approval completed — reopen pairing and try again.")
            }
        }
    }

    private func openPrivacyPane(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

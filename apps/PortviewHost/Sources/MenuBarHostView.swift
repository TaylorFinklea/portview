// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import PortviewHostCore

/// Compact menu-bar popover: the "just let me connect" surface — status, the real QR + copy URL when
/// advertising, connected device + duration when live, and Start/Stop + Open window. The rich
/// permissions/telemetry/file-send flow stays in the window. Auto-starts hosting (idempotent) so the
/// menu bar can advertise even when the window is closed. The pairing surface stays reachable even
/// with sessions already connected (second-device enrollment, han.3); it's replaced by the Allow/Deny
/// enrollment prompt only while one is pending.
struct MenuBarHostView: View {
    let model: HostAppModel
    @Environment(\.openWindow) private var openWindow
    /// Expand/collapse for the "Paired devices (N)" surface — collapsed by default so it never
    /// crowds the 300pt popover.
    @State private var showPairedDevices = false
    /// The row + destructive action awaiting the confirmation dialog (product decision 1). Non-nil ⇒
    /// the dialog is presented; confirming calls the model, which then runs the LAContext gate. Retry
    /// is carried here too (Sol pass 4 F1): it runs the same durable, destructive `PairingStore.revoke`
    /// as Revoke, so it owes the same confirmation.
    @State private var pendingDestructive: PendingDestructiveAction?
    /// Separate from `pendingDestructive`, which is device-scoped (every `RecoveryAction` needs a
    /// `PairedDeviceRow`); the store-wide reset has no row.
    @State private var resetConfirmationShown = false

    /// One queued destructive action. `RecoveryAction.requiresConfirmation` is what decides whether a
    /// button routes through here at all, so the dialog can never be skipped for a destructive action
    /// by forgetting a call site.
    private struct PendingDestructiveAction: Identifiable {
        let row: PairedDeviceRow
        let action: RecoveryAction
        var id: String { "\(row.id)-\(action.title)" }
    }

    private var readyDetails: HostReadyDetails? {
        if case .ready(let details) = model.state { return details } else { return nil }
    }
    private var statusText: String {
        switch model.state {
        case .idle: "Idle"
        case .starting: "Starting…"
        case .ready: "Host ready"
        case .failed: "Host failed — open the window for details"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
            Divider().overlay(Color.white.opacity(0.08))
            footer
        }
        .padding(16)
        .frame(width: 300)
        .background(Color(hex: 0x0E161A))
        .task {
            model.start() // idempotent: advertise even on a window-less launch
            model.startPermissionMonitoring() // refresh permission status when the popover opens
            await model.refreshEnrolledDevices() // §1a step 1: paired-devices surface-open refresh
        }
        // Destructive-action gate part 1 (product decision 1): confirm BEFORE the LAContext gate the
        // model runs. "Revoke 'iPhone'? It will lose access immediately."
        .confirmationDialog(
            pendingDestructive.map { "\($0.action.confirmation?.verb ?? "Revoke") '\($0.row.name)'?" } ?? "Revoke device?",
            isPresented: Binding(get: { pendingDestructive != nil },
                                 set: { presented in if !presented { pendingDestructive = nil } }),
            titleVisibility: .visible,
            presenting: pendingDestructive
        ) { pending in
            Button(pending.action.confirmation?.verb ?? "Revoke", role: .destructive) {
                perform(pending.action, on: pending.row)
                pendingDestructive = nil
            }
            Button("Cancel", role: .cancel) { pendingDestructive = nil }
        } message: { pending in
            Text(pending.action.confirmation?.message ?? "It will lose access immediately.")
        }
    }

    /// Route one recovery action to the model. Destructive actions are never invoked from here without
    /// having passed the confirmation dialog first — `recoveryButton` sends them there — and the model
    /// runs the LAContext gate on every one of them.
    private func perform(_ action: RecoveryAction, on row: PairedDeviceRow) {
        switch action {
        case .revoke: model.revoke(row.id)
        case .retryRevoke: model.retryRevoke(row.id)
        case .cancelRevoke: model.cancelRevoke(row.id)
        case .finishPairing: model.finishPairing(row.id)
        }
    }

    private var header: some View {
        HStack {
            Text("Portview Host").font(.grotesk(15, .semibold)).foregroundStyle(Glass.text1)
            Spacer()
            if model.sessions.count > 0 {
                HStack(spacing: 6) {
                    StatusDot(kind: .signal, size: 6)
                    Text("\(model.sessions.count) connected").font(.mono(10)).foregroundStyle(Glass.signal)
                }
            }
        }
    }

    /// Enrollment prompt takes priority over everything else — it can only be pending while ready,
    /// and it must hide the pairing surface (only one ceremony reads/decides at a time). Otherwise,
    /// while ready, the pairing surface (QR + "pair with a code") stays reachable REGARDLESS of
    /// connected-session count — second-device enrollment post-promotion requires opening a new
    /// pairing window even while a first device is already connected — with the connected-device
    /// summary shown above it when there is one.
    @ViewBuilder private var content: some View {
        if let prompt = model.enrollmentPrompt {
            enrollmentPromptView(prompt)
        } else if let details = readyDetails {
            VStack(alignment: .leading, spacing: 10) {
                if model.sessions.count > 0 {
                    connectedSummary
                    Divider().overlay(Glass.text3.opacity(0.2))
                }
                pairingSurface(details)
                pairedDevicesSection
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(statusText).font(.system(size: 12.5)).foregroundStyle(Glass.text2)
                if !model.onboarding.allGranted {
                    Text("Open the window to grant permissions.")
                        .font(.mono(10)).foregroundStyle(Glass.text3)
                }
            }
        }
    }

    private var connectedSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.sessions.primaryName ?? "iPhone")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Glass.text1Bright)
            if let since = model.connectedSince {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(since)))
                    Text("connected \(HostFormat.sessionDuration(seconds))")
                        .font(.mono(11)).foregroundStyle(Glass.text2)
                }
            }
        }
    }

    private func pairingSurface(_ details: HostReadyDetails) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                StatusDot(kind: .signal, size: 6)
                Text("Advertising as \(details.serviceName)")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Glass.text1)
            }
            // BOTH pairing paths — scanning this QR and typing the 6-digit code — end in the
            // enrollment ceremony, which refuses unless the pairing window is open
            // (`HostRunner.runEnrollmentCeremony` guards on `sas?.isOpen()`). A live-looking QR
            // beside a closed window is a dead affordance: the client dials, signs the challenge,
            // is classified `.unknownKey`, and is silently closed (bead portview-7hn). So the
            // window governs the QR and the code alike — dim what cannot work, and say why.
            QRCodeView(string: details.pairingURL)
                .frame(width: 132, height: 132)
                .padding(8)
                .background(Color(hex: 0x0A1416), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Glass.signal.opacity(0.2), lineWidth: 1))
                .opacity(model.isPairing ? 1 : 0.2)
                .overlay {
                    if !model.isPairing {
                        Text("Open the pairing\nwindow to scan")
                            .font(.mono(10)).foregroundStyle(Glass.text1)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            Text("Pin  \(HostFormat.groupedPin(details.pinHex))")
                .font(.mono(11)).foregroundStyle(Glass.text2)
            Button { model.copyPairingURL() } label: {
                Label("Copy pairing URL", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(!model.isPairing)

            Divider().overlay(Glass.text3.opacity(0.2))
            if model.isPairing {
                if model.clientConfirmed {
                    Label("a client confirmed", systemImage: "checkmark.seal.fill")
                        .font(.mono(11)).foregroundStyle(Glass.signal)
                }
                if let code = model.displayedSASCode {
                    Text("Enter this code on the iPhone")
                        .font(.mono(10)).foregroundStyle(Glass.text2)
                    Text(code)
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundStyle(Glass.signal)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    Text("Pairing window open — scan the QR above, or tap the Mac on your iPhone and enter the code shown here.")
                        .font(.mono(10)).foregroundStyle(Glass.text2)
                }
                Button("Cancel pairing") { model.endPairing() }
                    .buttonStyle(NeutralButtonStyle())
            } else {
                // Governs BOTH pairing paths, not just the code — see the QR comment above.
                Button { model.beginPairing() } label: {
                    Label("Open pairing window", systemImage: "lock.open")
                }
                .buttonStyle(NeutralButtonStyle())
            }
        }
    }

    /// The Allow/Deny ceremony prompt (han.3): fingerprint in 5 monospaced groups (already
    /// space-grouped by `KeyFingerprint.short`), the claimed device name, and the full-compare
    /// instruction — mirrors design v2's copy ("a device calling itself 'X'" / "compare ALL FIVE
    /// groups"). Both Allow and Deny are gated behind LAContext (`HostAppModel.approveEnrollment` /
    /// `denyEnrollment` — review Finding GLM2: a remote-injected click on either button must do
    /// nothing without local presence); this view never touches LocalAuthentication directly.
    private func enrollmentPromptView(
        _ prompt: (attemptID: UUID, fingerprint: String, claimedName: String, expiresAt: Date)
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                StatusDot(kind: .amber, size: 6)
                Text("A device calling itself '\(prompt.claimedName)'")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Glass.text1)
            }
            Text(prompt.fingerprint)
                .font(.mono(15, .semibold)).foregroundStyle(Glass.signal)
                .frame(maxWidth: .infinity, alignment: .center)
            Text("Compare ALL FIVE groups with your phone before allowing.")
                .font(.mono(10)).foregroundStyle(Glass.text2)
            HStack(spacing: 10) {
                Button("Deny") { model.denyEnrollment(prompt.attemptID) }
                    .buttonStyle(OutlineButtonStyle(tint: Glass.danger))
                    .disabled(model.enrollmentDecisionInFlight(for: prompt.attemptID))
                Spacer()
                Button("Allow") { model.approveEnrollment(prompt.attemptID) }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(model.enrollmentDecisionInFlight(for: prompt.attemptID))
            }
        }
    }

    /// The "Paired devices (N)" surface (design §1a step 1). A collapsed-by-default disclosure below
    /// the pairing surface so it never crowds the popover. Each row shows the device name, its compare
    /// fingerprint (mono — fingerprint ONLY, never the raw public key), and a relative last-seen; the
    /// per-row Revoke opens the confirmation dialog (then `model.revoke` runs the LAContext gate). A
    /// row whose durable revoke threw shows the incomplete Retry / Cancel pair instead.
    @ViewBuilder private var pairedDevicesSection: some View {
        if !model.enrolledDevices.isEmpty {
            Divider().overlay(Glass.text3.opacity(0.2))
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showPairedDevices.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showPairedDevices ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Paired devices (\(model.enrolledDevices.count))")
                            .font(.system(size: 12.5, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(Glass.text1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // The intent item is on the authorization path (§6d/R11): when it can't be read,
                // `PairingStore` denies EVERY device while this list still renders from the warm
                // authorization cache. Showing the rows with no explanation would read as "all fine".
                if model.pairingStoreUnreadable {
                    HStack(alignment: .top, spacing: 6) {
                        StatusDot(kind: .amber, size: 6)
                        Text("Pairing store unreadable — no device can connect until the keychain is available.")
                            .font(.mono(10)).foregroundStyle(Glass.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if showPairedDevices {
                    ForEach(model.enrolledDevices) { row in
                        pairedDeviceRow(row)
                    }
                }
            }
        } else if model.lockedOut {
            // Last-device lockout (product decision 2): the section that just held the revoked device
            // is gone, so surface the locked-out copy HERE, in the popover where the revoke happened —
            // not only in the main-window activity log.
            Divider().overlay(Glass.text3.opacity(0.2))
            HStack(alignment: .top, spacing: 6) {
                StatusDot(kind: .amber, size: 6)
                Text("No paired devices — Portview accepts no one until you re-pair in person.")
                    .font(.mono(10)).foregroundStyle(Glass.text2)
            }
        }
    }

    /// One recovery button. Destructive actions (`requiresConfirmation`) go to the confirmation dialog
    /// first and reach the model only after it; the rest call straight through to a model method that
    /// runs its own LAContext gate. Routing through `RecoveryAction` is what keeps the dialog from
    /// being skipped by an inconsistent call site.
    private func recoveryButton(_ action: RecoveryAction, _ row: PairedDeviceRow) -> some View {
        Button(action.title) {
            if action.requiresConfirmation {
                pendingDestructive = PendingDestructiveAction(row: row, action: action)
            } else {
                perform(action, on: row)
            }
        }
        .buttonStyle(OutlineButtonStyle(tint: action.isDestructive ? Glass.danger : Glass.text2))
    }

    private func pairedDeviceRow(_ row: PairedDeviceRow) -> some View {
        // The ONE provenance-aware state the whole row reads (Sol pass 4 F1/F2): its warning copy, its
        // status line, the activity-log line the model appends, and which actions it may offer all
        // come from here, so no two of them can describe the device differently. A device fenced by a
        // FAILED ENROLLMENT is `.enrollmentUnverified` — never the revoke row — because that row's
        // Retry runs a durable, destructive removal nobody authorized for it.
        let status = model.status(of: row.id)
        return VStack(alignment: .leading, spacing: 4) {
            Text(row.name)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Glass.text1Bright)
            Text(row.fingerprint)
                .font(.mono(10)).foregroundStyle(Glass.text2)
            Text("last seen \(row.lastSeen, format: .relative(presentation: .named))")
                .font(.mono(9)).foregroundStyle(Glass.text3)
            if let warning = DeviceStatusCopy.rowWarning(status) {
                Text(warning)
                    .font(.mono(9, .semibold)).foregroundStyle(Glass.dangerText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if let line = DeviceStatusCopy.rowStatusLine(status) {
                    Text(line).font(.mono(9, .semibold)).foregroundStyle(Glass.dangerText)
                }
                Spacer()
                ForEach(status.recoveryActions, id: \.self) { recoveryButton($0, row) }
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: Glass.well, style: .continuous))
    }

    private var footer: some View {
        VStack(spacing: 8) {
            // CloudKit re-wake nudge: writes a wantsReconnect beacon so a backgrounded iPhone gets a
            // silent push and offers tap-to-resume. Visible only when the write can actually happen
            // (hosting ready + CloudKit-entitled build) — never a success claim for a dropped write.
            if model.canAskReconnect {
                Button { model.askIPhoneToReconnect() } label: {
                    Label("Ask iPhone to reconnect", systemImage: "iphone.and.arrow.forward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(NeutralButtonStyle())
            }
            HStack {
                // "Stop" stops hosting but keeps the app resident in the menu bar; "Quit" below exits.
                if model.isRunning {
                    Button("Stop") { model.stop() }.buttonStyle(NeutralButtonStyle())
                } else {
                    Button("Start Hosting") { model.start() }.buttonStyle(AccentButtonStyle())
                }
                Spacer()
                Button("Open window") {
                    openWindow(id: PortviewHostApp.mainWindowID)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(NeutralButtonStyle())
            }
            // Break-glass repair. It lives in the FOOTER, not in `pairedDevicesSection`, because
            // that section renders only when `enrolledDevices` is non-empty — and in the very modes
            // this cures (an unreadable authorization or intent item) `list()` fail-closes to empty
            // while `lockedOut` stays false, so the whole section, banner included, draws nothing.
            // A recovery action you cannot see in the state it recovers from is not a recovery.
            Button("Reset pairing…") { resetConfirmationShown = true }
                .buttonStyle(.plain)
                .font(.mono(11))
                .foregroundStyle(Glass.text3)
                .frame(maxWidth: .infinity, alignment: .center)
                .confirmationDialog("Forget every paired device?",
                                    isPresented: $resetConfirmationShown, titleVisibility: .visible) {
                    Button("Forget all and quit", role: .destructive) { model.resetPairing() }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Repairs Portview's pairing store when no device can connect. Every pairing "
                         + "is forgotten and every pending revocation is discarded — each device must "
                         + "pair again in person. Portview will quit. Quit any other Portview host first.")
                }
            Button("Quit Portview Host") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.mono(11))
                .foregroundStyle(Glass.dangerText)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

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
            QRCodeView(string: details.pairingURL)
                .frame(width: 132, height: 132)
                .padding(8)
                .background(Color(hex: 0x0A1416), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Glass.signal.opacity(0.2), lineWidth: 1))
                .frame(maxWidth: .infinity, alignment: .center)
            Text("Pin  \(HostFormat.groupedPin(details.pinHex))")
                .font(.mono(11)).foregroundStyle(Glass.text2)
            Button { model.copyPairingURL() } label: {
                Label("Copy pairing URL", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(AccentButtonStyle())

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
                    Text("Pairing window open — tap the Mac on your iPhone, then enter the code shown here.")
                        .font(.mono(10)).foregroundStyle(Glass.text2)
                }
                Button("Cancel pairing") { model.endPairing() }
                    .buttonStyle(NeutralButtonStyle())
            } else {
                Button { model.beginPairing() } label: {
                    Label("Pair with a 6-digit code", systemImage: "number")
                }
                .buttonStyle(NeutralButtonStyle())
            }
        }
    }

    /// The Allow/Deny ceremony prompt (han.3): fingerprint in 5 monospaced groups (already
    /// space-grouped by `KeyFingerprint.short`), the claimed device name, and the full-compare
    /// instruction — mirrors design v2's copy ("a device calling itself 'X'" / "compare ALL FIVE
    /// groups"). Allow is gated behind LAContext inside `HostAppModel.approveEnrollment`; this view
    /// never touches LocalAuthentication directly.
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
                Spacer()
                Button("Allow") { model.approveEnrollment(prompt.attemptID) }
                    .buttonStyle(AccentButtonStyle())
            }
        }
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
            Button("Quit Portview Host") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.mono(11))
                .foregroundStyle(Glass.dangerText)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

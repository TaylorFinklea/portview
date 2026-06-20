import SwiftUI
import PortviewHostCore

/// Compact menu-bar popover: the "just let me connect" surface — status, the real QR + copy URL when
/// advertising, connected device + duration when live, and Start/Stop + Open window. The rich
/// permissions/telemetry/file-send flow stays in the window. Auto-starts hosting (idempotent) so the
/// menu bar can advertise even when the window is closed.
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

    @ViewBuilder private var content: some View {
        if let details = readyDetails, model.sessions.count == 0 {
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
        } else if readyDetails != nil {
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

    private var footer: some View {
        HStack {
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
    }
}

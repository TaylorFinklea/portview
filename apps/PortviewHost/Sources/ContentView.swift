import SwiftUI
import PortviewHostCore

/// The macOS host window in the Glass HUD language. Three states, all driven by `HostAppModel`:
/// permissions (first run), ready-to-pair (advertising + real QR), and device-connected (live
/// session stats + remote-input control). No fabricated data — everything reads the real model.
struct ContentView: View {
    let model: HostAppModel

    private enum PermissionStatus { case granted, needsPermission, pending }

    private var isReady: Bool { if case .ready = model.state { return true } else { return false } }
    private var isFailed: Bool { if case .failed = model.state { return true } else { return false } }
    private var readyDetails: HostReadyDetails? {
        if case .ready(let details) = model.state { return details } else { return nil }
    }
    private var isConnected: Bool { model.sessions.count > 0 }

    private var screenRecordingStatus: PermissionStatus {
        if isReady || model.isRunning { return .granted }
        return isFailed ? .needsPermission : .pending
    }
    private var accessibilityStatus: PermissionStatus {
        guard model.isRunning else { return .pending }
        return model.accessibilityWarning == nil ? .granted : .needsPermission
    }

    var body: some View {
        GlassCanvas {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let details = readyDetails {
                    if isConnected {
                        connectedCard(details)
                        controlCards(details)
                    } else {
                        advertisingStatus(details)
                        pairingCard(details)
                    }
                } else {
                    permissionsCard
                    statusLine
                }
                if !displayedLog.isEmpty { activityLog }
                Spacer(minLength: 0)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 720, minHeight: 560)
        .task { model.start() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Portview Host")
                    .font(.grotesk(28, .bold)).tracking(-0.4)
                    .foregroundStyle(Glass.text1)
                Text("Runs the Mac host under Portview's own Screen Recording identity.")
                    .font(.system(size: 13))
                    .foregroundStyle(Glass.text2)
            }
            Spacer()
            if isConnected {
                HStack(spacing: 6) {
                    StatusDot(kind: .signal, size: 6)
                    Text("\(model.sessions.count) connected").font(.mono(10)).foregroundStyle(Glass.signal)
                }
            }
            if model.isRunning {
                Button("Stop Hosting") { model.stop() }.buttonStyle(NeutralButtonStyle())
            } else {
                Button("Start Hosting") { model.start() }.buttonStyle(AccentButtonStyle())
            }
        }
    }

    // MARK: - State A · permissions

    private var permissionsCard: some View {
        VStack(spacing: 0) {
            permissionRow(
                icon: "display", iconTint: Glass.signal,
                title: "Screen Recording", status: screenRecordingStatus,
                detail: "Required for viewing — lets the phone see your screen.",
                openSettings: model.openScreenRecordingSettings)
            Divider().overlay(Color.white.opacity(0.07)).padding(.vertical, 18)
            permissionRow(
                icon: "cursorarrow.motionlines", iconTint: Glass.degraded,
                title: "Accessibility", status: accessibilityStatus,
                detail: "Required for remote control. Viewing can start before this is granted.",
                openSettings: model.openAccessibilitySettings)
        }
        .padding(20)
        .glassCard()
    }

    private func permissionRow(icon: String, iconTint: Color, title: String, status: PermissionStatus, detail: String, openSettings: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(iconTint)
                .frame(width: 38, height: 38)
                .background(iconTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(iconTint.opacity(0.3), lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 9) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Glass.text1)
                    badge(for: status)
                }
                Text(detail).font(.system(size: 12)).foregroundStyle(Glass.text2)
            }
            Spacer()
            switch status {
            case .granted:
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .heavy)).foregroundStyle(Glass.signalInk)
                    .frame(width: 24, height: 24).background(Glass.signal, in: Circle())
            case .needsPermission, .pending:
                Button("Open Settings", action: openSettings)
                    .buttonStyle(OutlineButtonStyle(tint: status == .needsPermission ? Glass.degraded : Glass.text2))
            }
        }
    }

    @ViewBuilder
    private func badge(for status: PermissionStatus) -> some View {
        switch status {
        case .granted: PillBadge(text: "GRANTED", style: .accent)
        case .needsPermission: PillBadge(text: "NEEDS PERMISSION", style: .amber)
        case .pending: PillBadge(text: "REQUIRED", style: .neutral)
        }
    }

    private var statusLine: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon).font(.system(size: 15)).foregroundStyle(Glass.text2)
            Text(statusText).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(hex: 0xBEC9C4))
        }
    }

    private var statusIcon: String {
        switch model.state {
        case .idle: "pause.circle"
        case .starting: "hourglass"
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusText: String {
        switch model.state {
        case .idle: "Idle — grant Accessibility, then Start Hosting"
        case .starting: "Starting host…"
        case .ready: "Host ready"
        case .failed(let message): message
        }
    }

    // MARK: - State B · ready to pair

    private func advertisingStatus(_ details: HostReadyDetails) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .heavy)).foregroundStyle(Glass.signalInk)
                .frame(width: 20, height: 20).background(Glass.signal, in: Circle())
                .shadow(color: Glass.signal.opacity(0.5), radius: 10)
            Text("Advertising as \(details.serviceName)")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Glass.text1)
            HStack(spacing: 6) {
                StatusDot(kind: .signal, size: 6)
                Text("bonjour · _portview._udp").font(.mono(10)).foregroundStyle(Glass.signal)
            }
            .padding(.leading, 4)
            Spacer()
        }
    }

    private func pairingCard(_ details: HostReadyDetails) -> some View {
        HStack(alignment: .top, spacing: 22) {
            QRCodeView(string: details.pairingURL)
                .frame(width: 168, height: 168)
                .padding(10)
                .background(Color(hex: 0x0A1416), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Glass.signal.opacity(0.2), lineWidth: 1))
                .shadow(color: Glass.signal.opacity(0.08), radius: 16)

            VStack(alignment: .leading, spacing: 0) {
                Text("Scan to pair").font(.grotesk(16, .semibold)).foregroundStyle(Glass.text1Bright)
                Text("Open Portview on your iPhone and scan this code, or enter the details by hand.")
                    .font(.system(size: 12.5)).foregroundStyle(Glass.text2)
                    .padding(.top, 4).padding(.bottom, 14)
                VStack(alignment: .leading, spacing: 9) {
                    detailRow("Service", details.serviceName)
                    detailRow("Address", "\(details.address) : \(details.port)")
                    detailRow("Pin", HostFormat.groupedPin(details.pinHex))
                    detailRow("Pairing URL", details.pairingURL, valueColor: Glass.signal, mono: true)
                }
                Button {
                    model.copyPairingURL()
                } label: {
                    Label("Copy pairing URL", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(AccentButtonStyle())
                .padding(.top, 16)
            }
        }
        .padding(22)
        .glassCard(cornerRadius: 16, accent: true)
    }

    private func detailRow(_ label: String, _ value: String, valueColor: Color = Glass.text1, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.mono(12)).foregroundStyle(Glass.text3).frame(width: 76, alignment: .leading)
            Text(value)
                .font(.mono(12))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    // MARK: - State C · connected

    private func connectedCard(_ details: HostReadyDetails) -> some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "iphone")
                    .font(.system(size: 19)).foregroundStyle(Glass.signal)
                    .frame(width: 42, height: 42)
                    .background(Glass.signal.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Glass.signal.opacity(0.35), lineWidth: 1))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 9) {
                        Text(model.sessions.primaryName ?? "iPhone")
                            .font(.system(size: 17, weight: .semibold)).foregroundStyle(Glass.text1Bright)
                        StatusDot(kind: .signal, size: 8)
                    }
                    TimelineView(.periodic(from: model.connectedSince ?? .now, by: 1)) { context in
                        let seconds = model.connectedSince.map { max(0, Int(context.date.timeIntervalSince($0))) } ?? 0
                        Text("on this network · connected \(HostFormat.sessionDuration(seconds))")
                            .font(.mono(11)).foregroundStyle(Glass.text2)
                    }
                }
                Spacer()
                Button("Disconnect") { model.disconnectClients() }
                    .buttonStyle(OutlineButtonStyle(tint: Glass.danger))
            }
            HStack(spacing: 10) {
                let stats = model.sessions.latestStats
                statWell("THROUGHPUT", value(stats?.throughputMbps, "%.1f"), "Mbps", hero: true)
                statWell("FRAME", value(stats?.fps, "%.0f"), "fps")
                statWell("ENCODE", value(stats?.encodeMs, "%.1f"), "ms")
                statWell("DISPLAY", dimensionValue(stats), "")
            }
        }
        .padding(20)
        .glassCard(cornerRadius: 16, accent: true)
    }

    private func controlCards(_ details: HostReadyDetails) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "display").font(.system(size: 16)).foregroundStyle(Glass.signal)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sharing \(sharingDisplayLabel)").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Glass.text1)
                    Text(sharingDisplayDetail).font(.system(size: 11)).foregroundStyle(Glass.text2)
                }
                Spacer()
            }
            .padding(.horizontal, 17).padding(.vertical, 15)
            .glassCard()

            Button {
                if accessibilityStatus != .granted { model.openAccessibilitySettings() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "cursorarrow.motionlines").font(.system(size: 16)).foregroundStyle(Glass.signal)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Remote input").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Glass.text1)
                        Text(accessibilityStatus == .granted
                             ? "Accessibility granted · keyboard & mouse"
                             : "Accessibility needed · click to open Settings")
                            .font(.system(size: 11)).foregroundStyle(Glass.text2)
                    }
                    Spacer()
                    PillToggle(on: accessibilityStatus == .granted)
                }
                .padding(.horizontal, 17).padding(.vertical, 15)
                .glassCard(accent: accessibilityStatus == .granted)
            }
            .buttonStyle(.plain)
        }
    }

    private func statWell(_ label: String, _ value: String, _ unit: String, hero: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).eyebrow(8.5).foregroundStyle(Glass.text3)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.grotesk(19, .bold)).foregroundStyle(hero ? Glass.signal : Glass.text1)
                if !unit.isEmpty { Text(unit).font(.system(size: 10)).foregroundStyle(Glass.text2) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .telemetryWell()
    }

    // MARK: - Activity log

    /// The concise operational log — CLI-only multi-line artifacts (the ASCII box + terminal QR) are
    /// filtered out so the GUI log stays clean; no lines are fabricated.
    private var displayedLog: [String] {
        model.messages.filter { !$0.contains("\n") && $0.count < 160 }
    }

    private var activityLog: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(displayedLog.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.mono(11))
                        .foregroundStyle(Color(hex: 0x7E8C86))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 15).padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 120)
        .telemetryWell(cornerRadius: 12)
    }

    // MARK: - Derived values

    private var sharingDisplayLabel: String {
        if let stats = model.sessions.latestStats { return "Display (\(stats.displayWidth)×\(stats.displayHeight))" }
        return "Display"
    }
    private var sharingDisplayDetail: String {
        if let stats = model.sessions.latestStats { return "Built-in · \(stats.displayWidth)×\(stats.displayHeight)" }
        return "Built-in display"
    }
    private func value(_ number: Double?, _ format: String) -> String {
        guard let number else { return "—" }
        return String(format: format, number)
    }
    private func dimensionValue(_ stats: HostSessionStats?) -> String {
        guard let stats else { return "—" }
        return "\(stats.displayWidth)×\(stats.displayHeight)"
    }
}

/// A read-only toggle visual reflecting a permission state (on = signal, off = neutral).
private struct PillToggle: View {
    let on: Bool
    var body: some View {
        Capsule()
            .fill(on ? AnyShapeStyle(Glass.signal) : AnyShapeStyle(Color.white.opacity(0.12)))
            .frame(width: 42, height: 24)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle()
                    .fill(on ? Glass.signalInk : Glass.text2)
                    .frame(width: 20, height: 20)
                    .padding(2)
            }
            .shadow(color: on ? Glass.signal.opacity(0.4) : .clear, radius: 8)
    }
}

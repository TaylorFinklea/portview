import SwiftUI
import PortviewClientCore
import PortviewProtocol

/// Screens 4–6 — the live control surface over the streamed Mac. Re-skins the existing streaming
/// machinery (TrackpadVideoView + ZoomGeometry + KeyboardCaptureView) in the Glass HUD language and
/// adds the degraded "reconnecting" treatment when `SessionViewModel.status == .reconnecting`.
struct LiveHUDView: View {
    @ObservedObject var session: SessionViewModel
    @Binding var zoom: CGFloat
    @Binding var showQualityHUD: Bool
    @Binding var samplerMode: VideoSamplerMode
    @Binding var keyboardActive: Bool
    @Binding var armed: KeyModifiers
    @Binding var showFileImporter: Bool

    private let modifierKeys: [(label: String, mod: KeyModifiers)] = [
        ("⌘", .command), ("⇧", .shift), ("⌥", .option), ("⌃", .control)
    ]
    private var isReconnecting: Bool { session.status == .reconnecting }
    private var isHostLocked: Bool { session.hostLocked }
    private var hostName: String { session.hostName ?? "Mac" }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            // Used here only for the host crop request; the renderer's eased cursor-follow window is
            // driven from the session (renderer.targetWindow).
            let zoomGeometry = ZoomGeometry(
                view: size, displaySize: session.displaySize,
                cursor: session.cursorNormalized, zoom: zoom)

            ZStack {
                TrackpadVideoView(
                    renderer: session.renderer,
                    zoom: zoom,
                    onMove: { dx, dy in session.sendPointerMove(dx: dx, dy: dy) },
                    onScroll: { dx, dy in session.sendScroll(dx: dx, dy: dy) },
                    onClick: { session.sendClick() },
                    onZoom: { zoom = min(6, max(1, $0)) }
                )
                .frame(width: size.width, height: size.height)
                // Zoom is applied in the Metal shader (sampleRect), NOT as a CA scaleEffect — so the
                // present is synchronized (no tear) and the on-screen window is invariant to host
                // re-crops (no jump). The session computes the sample rect per-frame against each
                // frame's own region (atomic); the view just supplies the zoom + its size.
                .onChange(of: zoom) { _, z in session.magnifierZoom = z }
                .onChange(of: size) { _, s in session.magnifierViewSize = s }
                .onChange(of: zoomGeometry.cropRequest) { _, crop in
                    session.requestViewport(crop: crop, window: zoomGeometry.visibleWindow)
                }
                .allowsHitTesting(!isReconnecting && !isHostLocked)
                .overlay {
                    if isReconnecting || isHostLocked {
                        Color(hex: 0x080B0E, opacity: 0.58).blur(radius: 0.5)
                    }
                }

                KeyboardCaptureView(
                    isActive: $keyboardActive,
                    onText: { text in
                        if armed.isEmpty {
                            session.sendText(text)
                        } else {
                            session.sendChar(text, modifiers: armed)
                            armed = []
                        }
                    },
                    onSpecial: { key in
                        session.sendKey(key, modifiers: armed)
                        armed = []
                    }
                )
                .frame(width: 0, height: 0)

                chrome(size: size)
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
                if case .success(let url) = result {
                    guard url.startAccessingSecurityScopedResource() else { return }
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let data = try? Data(contentsOf: url) {
                        session.sendFile(name: url.lastPathComponent, data: data)
                    }
                }
            }
            .onAppear {
                session.renderer.samplerMode = samplerMode
                session.magnifierViewSize = size
                session.magnifierZoom = zoom
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Chrome

    @ViewBuilder
    private func chrome(size: CGSize) -> some View {
        VStack(spacing: 8) {
            telemetryRail
            HStack(alignment: .top) {
                if zoom > 1.01 { magnifierPill }
                Spacer()
                toolbar
            }
            Spacer()
            bottomControls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 10)
        .padding(.top, 52)
        .padding(.bottom, 30)
        .overlay {
            if isReconnecting { reconnectingCard }
            else if isHostLocked { hostLockedCard }
        }
    }

    private var telemetryRail: some View {
        let readout = TelemetryReadout(session.qualityDiagnostics)
        let trailing: String = {
            if isReconnecting { return "ip changed" }
            if keyboardActive { return "keys → host" }
            return "\(readout.link) Mbps · \(readout.frame) fps"
        }()
        return HStack(spacing: 8) {
            StatusDot(kind: isReconnecting ? .degraded : .live, size: 6)
            Text(hostName).font(.mono(9.5)).foregroundStyle(Glass.text1)
            Text(isReconnecting ? "reconnecting…" : "live")
                .font(.mono(9.5))
                .foregroundStyle(isReconnecting ? Glass.degraded : Glass.signal)
            Spacer()
            Text(trailing).font(.mono(9.5)).foregroundStyle(Glass.text2)
        }
        .padding(.horizontal, 11)
        .frame(height: 26)
        .glassPanel(cornerRadius: Glass.rail, accent: !isReconnecting)
        .overlay {
            if isReconnecting {
                RoundedRectangle(cornerRadius: Glass.rail, style: .continuous)
                    .strokeBorder(Glass.degraded.opacity(0.45), lineWidth: 1)
            }
        }
    }

    private var magnifierPill: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 9, weight: .semibold))
            Text(String(format: "%.1f×", zoom)).font(.mono(10))
        }
        .foregroundStyle(Glass.signal)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(Glass.signal.opacity(0.25), lineWidth: 1))
    }

    private var toolbar: some View {
        VStack(spacing: 9) {
            // Reset-zoom only appears while zoomed (interaction rule); core order then follows the
            // README: gauge → keyboard → paste → file, with sampler/display as conditional extras.
            if zoom > 1.01 {
                toolButton("minus.magnifyingglass") { zoom = 1 }
            }
            toolButton("gauge", active: showQualityHUD) { showQualityHUD.toggle() }
            toolButton(keyboardActive ? "keyboard.chevron.compact.down" : "keyboard", active: keyboardActive) {
                keyboardActive.toggle()
            }
            toolButton("doc.on.clipboard") { session.pasteToHost() }
            toolButton("arrow.up.doc") { showFileImporter = true }
            if showQualityHUD {
                toolButton(samplerMode == .linear ? "circle.lefthalf.filled" : "circle.righthalf.filled") {
                    samplerMode = samplerMode.next
                    session.renderer.samplerMode = samplerMode
                }
            }
            if session.displays.count > 1 {
                Menu {
                    ForEach(session.displays, id: \.id) { display in
                        Button {
                            zoom = 1
                            session.switchDisplay(to: display.id)
                        } label: {
                            Label(display.name,
                                  systemImage: display.id == session.activeDisplayID ? "checkmark" : "display")
                        }
                    }
                } label: {
                    toolButtonLabel("rectangle.on.rectangle", active: false)
                }
            }
            toolButton("rectangle.portrait.and.arrow.right", danger: true) { session.disconnect() }
        }
        .disabled(isReconnecting)
        .opacity(isReconnecting ? 0.5 : 1)
    }

    private func toolButton(_ systemImage: String, active: Bool = false, danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            toolButtonLabel(systemImage, active: active, danger: danger)
        }
        .buttonStyle(.plain)
    }

    private func toolButtonLabel(_ systemImage: String, active: Bool, danger: Bool = false) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(active ? Glass.signalInk : (danger ? Glass.dangerText : Glass.text1))
            .frame(width: 36, height: 36)
            .background {
                if active {
                    RoundedRectangle(cornerRadius: Glass.button, style: .continuous).fill(Glass.accentFill)
                } else {
                    RoundedRectangle(cornerRadius: Glass.button, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(RoundedRectangle(cornerRadius: Glass.button, style: .continuous)
                            .fill(Color.white.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: Glass.button, style: .continuous)
                            .strokeBorder((danger ? Glass.danger : Color.white).opacity(danger ? 0.4 : 0.14), lineWidth: 1))
                }
            }
            .shadow(color: active ? Glass.signal.opacity(0.45) : .clear, radius: active ? 10 : 0)
    }

    @ViewBuilder
    private var bottomControls: some View {
        VStack(spacing: 8) {
            if let transfer = session.transferStatus {
                HStack {
                    Text(transfer).font(.mono(10)).foregroundStyle(Glass.text1)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .glassPanel(cornerRadius: 10)
                    Spacer()
                }
            }
            if showQualityHUD && !isReconnecting {
                QualityPanel(
                    diagnostics: session.qualityDiagnostics,
                    displayLabel: "\(hostName.uppercased()) · DISPLAY \(session.activeDisplayID)")
            }
            if keyboardActive { modifierDock }
            gestureLegend
        }
    }

    private var modifierDock: some View {
        HStack(spacing: 6) {
            ForEach(modifierKeys.indices, id: \.self) { i in
                let entry = modifierKeys[i]
                let on = armed.contains(entry.mod)
                Button {
                    armed.formSymmetricDifference(entry.mod)
                } label: {
                    Text(entry.label)
                        .font(.mono(12, .semibold))
                        .foregroundStyle(on ? Glass.signalInk : Glass.text1)
                        .frame(width: 34, height: 30)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Glass.signal)
                            } else {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                            }
                        }
                        .shadow(color: on ? Glass.signal.opacity(0.5) : .clear, radius: on ? 10 : 0)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text(armedCaption)
                .font(.mono(9))
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Glass.signal)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .glassPanel(accent: true)
    }

    private var armedCaption: String {
        let active = modifierKeys.filter { armed.contains($0.mod) }.map(\.label)
        return active.isEmpty ? "type to send" : "\(active.joined()) armed ·\nnext key chords"
    }

    private var gestureLegend: some View {
        Text("drag·move   tap·click   2-finger·scroll   pinch·zoom")
            .font(.mono(8.5))
            .foregroundStyle(Glass.text1.opacity(0.4))
            .frame(maxWidth: .infinity)
    }

    private var reconnectingCard: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                SpinnerRing(diameter: 50, lineWidth: 3, color: Glass.degraded) { EmptyView() }
                Text("Reconnecting to \(hostName)")
                    .font(.grotesk(17, .semibold))
                    .foregroundStyle(Glass.text1Bright)
                Text("the Mac's IP changed — re-binding over Bonjour. Input paused.")
                    .font(.mono(10))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Glass.text2)
                    .padding(.horizontal, 4)
            }
            .padding(20)
            .glassPanel()
            .overlay(RoundedRectangle(cornerRadius: Glass.sheet, style: .continuous)
                .strokeBorder(Glass.degraded.opacity(0.3), lineWidth: 1))
            .padding(.horizontal, 34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hostLockedCard: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(Glass.degraded)
                Text("\(hostName) is locked")
                    .font(.grotesk(17, .semibold))
                    .foregroundStyle(Glass.text1Bright)
                Text("screen capture paused — unlock the Mac to resume. Input paused.")
                    .font(.mono(10))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Glass.text2)
                    .padding(.horizontal, 4)
            }
            .padding(20)
            .glassPanel()
            .overlay(RoundedRectangle(cornerRadius: Glass.sheet, style: .continuous)
                .strokeBorder(Glass.degraded.opacity(0.3), lineWidth: 1))
            .padding(.horizontal, 34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

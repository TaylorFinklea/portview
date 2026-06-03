import SwiftUI
import UniformTypeIdentifiers
import PortviewProtocol
import PortviewTransport

struct ContentView: View {
    @StateObject private var session = SessionViewModel()
    @StateObject private var discovery = DiscoveryModel()
    @StateObject private var savedHosts = SavedHostsStore()
    /// Pairing to persist if the in-flight connection reaches `.streaming`.
    @State private var pendingSave: PairingPayload?
    @State private var host = ""
    @State private var port = ""
    @State private var pin = ""
    @State private var showScanner = false
    @State private var showFileImporter = false
    @State private var zoom: CGFloat = 1
    @State private var keyboardActive = false
    /// Sticky modifiers armed for the next keystroke (cleared after it's sent).
    @State private var armed: KeyModifiers = []

    private let modifierKeys: [(label: String, mod: KeyModifiers)] = [
        ("⌘", .command), ("⇧", .shift), ("⌥", .option), ("⌃", .control)
    ]

    var body: some View {
        if session.status == .streaming {
            GeometryReader { geo in
                let size = geo.size
                // Target viewport: the display region the gesture wants, aspect-preserving (equal
                // width/height fractions = 1/zoom), centered on the cursor and clamped on-screen.
                let tw = min(1, 1 / zoom)
                let target = CGRect(
                    x: min(max(0, session.cursorNormalized.x - tw / 2), 1 - tw),
                    y: min(max(0, session.cursorNormalized.y - tw / 2), 1 - tw),
                    width: tw, height: tw)
                // The Metal renderer aspect-fits the (display-aspect) video; its rect inside the view.
                let videoAspect = session.displaySize.width / max(1, session.displaySize.height)
                let viewAspect = size.width / max(1, size.height)
                let videoSize = videoAspect > viewAspect
                    ? CGSize(width: size.width, height: size.width / videoAspect)
                    : CGSize(width: size.height * videoAspect, height: size.height)
                let videoOrigin = CGPoint(x: (size.width - videoSize.width) / 2,
                                          y: (size.height - videoSize.height) / 2)
                // The host already cropped its frames to `frameViewport`. Render the RESIDUAL zoom of
                // `target` on top of that: while the host catches up the residual provides instant
                // (digital) zoom; once frame == target the residual is identity → crisp host-cropped 1:1.
                let frame = session.frameViewport
                let residual = frame.width > 0 ? frame.width / target.width : 1
                let lfx = frame.width > 0 ? (target.midX - frame.minX) / frame.width : 0.5
                let lfy = frame.height > 0 ? (target.midY - frame.minY) / frame.height : 0.5
                let centerView = CGPoint(x: videoOrigin.x + lfx * videoSize.width,
                                         y: videoOrigin.y + lfy * videoSize.height)
                let limitX = max(0, (residual * videoSize.width - size.width) / 2)
                let limitY = max(0, (residual * videoSize.height - size.height) / 2)
                let panX = min(limitX, max(-limitX, residual * (size.width / 2 - centerView.x)))
                let panY = min(limitY, max(-limitY, residual * (size.height / 2 - centerView.y)))

                ZStack(alignment: .top) {
                    TrackpadVideoView(
                        renderer: session.renderer,
                        zoom: zoom,
                        onMove: { dx, dy in session.sendPointerMove(dx: dx, dy: dy) },
                        onScroll: { dx, dy in session.sendScroll(dx: dx, dy: dy) },
                        onClick: { session.sendClick() },
                        onZoom: { zoom = min(4, max(1, $0)) }
                    )
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(residual, anchor: .center)
                    .offset(x: panX, y: panY)
                    // Smooth the follow so throttled host cursor reports don't make the pan jitter,
                    // while staying responsive (short, critically damped — no overshoot).
                    .animation(.spring(response: 0.1, dampingFraction: 1.0), value: session.cursorNormalized)
                    // Tell the host to crop to the target region (the magnifier) as zoom/pan change.
                    .onChange(of: target) { _, newTarget in session.requestViewport(newTarget) }

                    // Invisible first-responder that surfaces the system keyboard when toggled.
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

                    VStack(spacing: 8) {
                        HStack(spacing: 10) {
                            Text("drag·move  tap·click  2-finger·scroll  pinch·zoom")
                                .font(.caption2)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                            Spacer()
                            if zoom > 1.01 {
                                Button { zoom = 1 } label: { Image(systemName: "minus.magnifyingglass") }
                                    .padding(8).background(.ultraThinMaterial, in: Circle())
                            }
                            if session.displays.count > 1 {
                                Menu {
                                    ForEach(session.displays, id: \.id) { display in
                                        Button {
                                            zoom = 1   // start the new display un-cropped
                                            session.switchDisplay(to: display.id)
                                        } label: {
                                            Label(display.name,
                                                  systemImage: display.id == session.activeDisplayID ? "checkmark" : "display")
                                        }
                                    }
                                } label: {
                                    Image(systemName: "rectangle.on.rectangle")
                                }
                                .padding(8).background(.ultraThinMaterial, in: Circle())
                            }
                            Button { session.pasteToHost() } label: { Image(systemName: "doc.on.clipboard") }
                                .padding(8).background(.ultraThinMaterial, in: Circle())
                            Button { showFileImporter = true } label: { Image(systemName: "arrow.up.doc") }
                                .padding(8).background(.ultraThinMaterial, in: Circle())
                            Button { keyboardActive.toggle() } label: {
                                Image(systemName: keyboardActive ? "keyboard.chevron.compact.down" : "keyboard")
                            }
                            .padding(8).background(.ultraThinMaterial, in: Circle())
                            Button("Disconnect") { session.disconnect() }
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(.ultraThinMaterial, in: Capsule())
                        }

                        // Sticky modifier bar — arm ⌘/⇧/⌥/⌃, then the next key forms a chord.
                        if keyboardActive {
                            HStack(spacing: 8) {
                                ForEach(modifierKeys.indices, id: \.self) { i in
                                    let entry = modifierKeys[i]
                                    let on = armed.contains(entry.mod)
                                    Button { armed.formSymmetricDifference(entry.mod) } label: {
                                        Text(entry.label)
                                            .font(.system(size: 17, weight: .semibold))
                                            .frame(width: 42, height: 36)
                                            .foregroundStyle(on ? Color.white : Color.primary)
                                            .background(
                                                on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.ultraThinMaterial),
                                                in: RoundedRectangle(cornerRadius: 8)
                                            )
                                    }
                                }
                                Spacer()
                            }
                        }

                        if let transferStatus = session.transferStatus {
                            HStack {
                                Text(transferStatus)
                                    .font(.caption2)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(.ultraThinMaterial, in: Capsule())
                                Spacer()
                            }
                        }
                    }
                    .padding()
                    .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
                        if case .success(let url) = result {
                            guard url.startAccessingSecurityScopedResource() else { return }
                            defer { url.stopAccessingSecurityScopedResource() }
                            if let data = try? Data(contentsOf: url) {
                                session.sendFile(name: url.lastPathComponent, data: data)
                            }
                        }
                    }
                }
            }
            .ignoresSafeArea()
        } else {
            NavigationStack {
                Form {
                    Section("Pair by QR") {
                        Button {
                            showScanner = true
                        } label: {
                            Label("Scan the QR shown on your Mac", systemImage: "qrcode.viewfinder")
                        }
                    }

                    if !savedHosts.hosts.isEmpty {
                        Section("Saved Macs") {
                            ForEach(savedHosts.hosts) { saved in
                                Button {
                                    pendingSave = saved.payload
                                    session.connect(payload: saved.payload)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(saved.name)
                                        Text("\(saved.host):\(String(saved.port))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .onDelete { savedHosts.remove(atOffsets: $0) }
                        }
                    }

                    if !discovery.hosts.isEmpty {
                        Section("Discovered Macs (enter the pin, then tap)") {
                            ForEach(discovery.hosts) { discovered in
                                Button(discovered.name) {
                                    session.connect(to: discovered, pinHex: pin)
                                }
                                .disabled(pin.isEmpty)
                            }
                        }
                    }

                    Section("Or connect manually") {
                        TextField("IP address", text: $host)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Port", text: $port)
                            .keyboardType(.numberPad)
                    }

                    Section("Pin") {
                        TextField("Pin (64 hex chars)", text: $pin)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                        Button("Connect manually") {
                            if let parsedPort = UInt16(port) {
                                pendingSave = PairingPayload(host: host, port: parsedPort, pinHex: pin, name: host)
                                session.connect(host: host, port: parsedPort, pinHex: pin)
                            }
                        }
                        .disabled(host.isEmpty || port.isEmpty || pin.isEmpty)
                    }

                    switch session.status {
                    case .connecting:
                        ProgressView("Connecting…")
                    case .failed(let message):
                        Text(message).foregroundStyle(.red)
                    default:
                        EmptyView()
                    }
                }
                .navigationTitle("🪟 Portview")
                .sheet(isPresented: $showScanner) {
                    QRScannerView { code in
                        showScanner = false
                        if let payload = PairingPayload(urlString: code) {
                            pendingSave = payload
                            session.connect(payload: payload)
                        }
                    }
                    .ignoresSafeArea()
                }
                .onChange(of: session.status) { _, newValue in
                    if newValue == .streaming, let payload = pendingSave {
                        savedHosts.remember(payload)
                        pendingSave = nil
                    }
                }
                .onAppear { discovery.start() }
                .onDisappear { discovery.stop() }
            }
        }
    }
}

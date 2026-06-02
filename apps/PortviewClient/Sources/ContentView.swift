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
                let z = zoom
                let limitX = (z - 1) * size.width / 2
                let limitY = (z - 1) * size.height / 2
                let panX = min(limitX, max(-limitX, z * (size.width / 2 - session.cursorNormalized.x * size.width)))
                let panY = min(limitY, max(-limitY, z * (size.height / 2 - session.cursorNormalized.y * size.height)))

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
                    .scaleEffect(z, anchor: .center)
                    .offset(x: panX, y: panY)

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

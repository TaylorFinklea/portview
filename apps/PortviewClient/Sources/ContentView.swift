import SwiftUI
import PortviewTransport

struct ContentView: View {
    @StateObject private var session = SessionViewModel()
    @StateObject private var discovery = DiscoveryModel()
    @State private var host = ""
    @State private var port = ""
    @State private var pin = ""
    @State private var showScanner = false
    @State private var zoom: CGFloat = 1
    @State private var keyboardActive = false

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
                        onText: { session.sendText($0) },
                        onSpecial: { session.sendKey($0) }
                    )
                    .frame(width: 0, height: 0)

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
                    Button { keyboardActive.toggle() } label: {
                        Image(systemName: keyboardActive ? "keyboard.chevron.compact.down" : "keyboard")
                    }
                    .padding(8).background(.ultraThinMaterial, in: Circle())
                    Button("Disconnect") { session.disconnect() }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                    .padding()
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
                            session.connect(payload: payload)
                        }
                    }
                    .ignoresSafeArea()
                }
                .onAppear { discovery.start() }
                .onDisappear { discovery.stop() }
            }
        }
    }
}

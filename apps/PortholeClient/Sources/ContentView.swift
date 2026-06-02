import SwiftUI
import PortholeTransport

struct ContentView: View {
    @StateObject private var session = SessionViewModel()
    @StateObject private var discovery = DiscoveryModel()
    @State private var host = ""
    @State private var port = ""
    @State private var pin = ""
    @State private var showScanner = false

    var body: some View {
        if session.status == .streaming {
            ZStack(alignment: .top) {
                TrackpadVideoView(
                    renderer: session.renderer,
                    onMove: { dx, dy in session.sendPointerMove(dx: dx, dy: dy) },
                    onScroll: { dx, dy in session.sendScroll(dx: dx, dy: dy) },
                    onClick: { session.sendClick() }
                )
                .ignoresSafeArea()
                HStack {
                    Text("drag = move · tap = click · 2-finger = scroll")
                        .font(.caption2)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                    Button("Disconnect") { session.disconnect() }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding()
            }
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
                .navigationTitle("🪟 Porthole")
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

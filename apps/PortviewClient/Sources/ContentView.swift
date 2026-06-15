import SwiftUI
import PortviewProtocol
import PortviewTransport

/// Top-level router for the Glass HUD client. Owns session/discovery/pairing state and the live HUD
/// controls; switches between the connect flow (Deck Home → Pair/Connecting) and the live surface.
struct ContentView: View {
    @StateObject private var session = SessionViewModel()
    @StateObject private var discovery = DiscoveryModel()
    @StateObject private var savedHosts = SavedHostsStore()
    @StateObject private var pairing = PairingCoordinator()

    @State private var manualHost = ""
    @State private var manualPort = ""
    @State private var manualPin = ""
    @State private var showScanner = false
    @State private var showManual = false
    @State private var showFileImporter = false
    @State private var pinPromptHost: DiscoveredHost?
    @State private var discoveredPin = ""

    // Live HUD state (kept here so it survives view switches; passed to LiveHUDView).
    @State private var zoom: CGFloat = 1
    @State private var showQualityHUD = false
    @State private var samplerMode: VideoSamplerMode = .linear
    @State private var keyboardActive = false
    @State private var armed: KeyModifiers = []

    var body: some View {
        content
            .preferredColorScheme(.dark)
            .fullScreenCover(isPresented: $showScanner) {
                PairView(
                    onConnect: { payload in
                        showScanner = false
                        pairing.markPending(payload)
                        session.connect(payload: payload)
                    },
                    onManual: { showScanner = false; showManual = true },
                    onClose: { showScanner = false })
            }
            .sheet(isPresented: $showManual) { manualConnectSheet }
            .alert("Pair with \(pinPromptHost?.name ?? "Mac")", isPresented: pinPromptPresented) {
                TextField("Pin (64 hex chars)", text: $discoveredPin)
                Button("Connect") {
                    if let host = pinPromptHost { session.connect(to: host, pinHex: discoveredPin) }
                    pinPromptHost = nil
                    discoveredPin = ""
                }
                Button("Cancel", role: .cancel) { pinPromptHost = nil; discoveredPin = "" }
            } message: {
                Text("Enter the pin shown on \(pinPromptHost?.name ?? "the Mac").")
            }
            .onChange(of: session.status) { _, status in
                if status == .streaming {
                    pairing.commitIfStreaming(true) { savedHosts.remember($0) }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch session.status {
        case .streaming, .reconnecting:
            LiveHUDView(
                session: session,
                zoom: $zoom,
                showQualityHUD: $showQualityHUD,
                samplerMode: $samplerMode,
                keyboardActive: $keyboardActive,
                armed: $armed,
                showFileImporter: $showFileImporter)
        case .connecting:
            ConnectingView(hostName: session.hostName ?? "Mac", onCancel: { session.disconnect() })
        case .idle, .failed:
            DeckHomeView(
                session: session,
                discovery: discovery,
                savedHosts: savedHosts,
                onReconnectSaved: { saved in
                    pairing.markPending(saved.payload)
                    session.reconnect(saved: saved, discovered: discovery.hosts)
                },
                onPickDiscovered: { host in
                    discoveredPin = ""
                    pinPromptHost = host
                },
                onScan: { showScanner = true },
                onManual: { showManual = true })
            .onAppear { discovery.start() }
            .onDisappear { discovery.stop() }
        }
    }

    private var pinPromptPresented: Binding<Bool> {
        Binding(get: { pinPromptHost != nil }, set: { if !$0 { pinPromptHost = nil } })
    }

    private var manualConnectSheet: some View {
        GlassCanvas(style: .deck) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Connect manually").font(.grotesk(22, .bold)).foregroundStyle(Glass.text1)
                    Spacer()
                    Button { showManual = false } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Glass.text2).frame(width: 30, height: 30)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
                manualField("IP address", text: $manualHost, keyboard: .numbersAndPunctuation)
                manualField("Port", text: $manualPort, keyboard: .numberPad)
                manualField("Pin (64 hex chars)", text: $manualPin, keyboard: .asciiCapable, mono: true)
                Button("Connect") {
                    guard let port = UInt16(manualPort) else { return }
                    let payload = PairingPayload(host: manualHost, port: port, pinHex: manualPin, name: manualHost)
                    pairing.markPending(payload)
                    session.connect(host: manualHost, port: port, pinHex: manualPin)
                    showManual = false
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(manualHost.isEmpty || manualPort.isEmpty || manualPin.isEmpty)
                .opacity(manualHost.isEmpty || manualPort.isEmpty || manualPin.isEmpty ? 0.5 : 1)
                Spacer()
            }
            .padding(20)
        }
        .preferredColorScheme(.dark)
    }

    private func manualField(_ placeholder: String, text: Binding<String>, keyboard: UIKeyboardType, mono: Bool = false) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundStyle(Glass.text3))
            .font(mono ? .mono(13) : .grotesk(14))
            .foregroundStyle(Glass.text1)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .glassCard()
    }
}

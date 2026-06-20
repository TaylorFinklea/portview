import SwiftUI
import PortviewProtocol
import PortviewTransport

/// Top-level router for the Glass HUD client. Owns session/discovery/pairing state and the live HUD
/// controls; switches between the connect flow (Deck Home → Pair/Connecting) and the live surface.
struct ContentView: View {
    @StateObject private var session = SessionViewModel()
    @StateObject private var discovery = DiscoveryModel()
    @StateObject private var savedHosts = SavedHostsStore()
    @StateObject private var settings = ClientSettingsStore()

    @State private var manualHost = ""
    @State private var manualPort = ""
    @State private var manualPin = ""
    @State private var showScanner = false
    @State private var showManual = false
    @State private var showSettings = false
    @State private var showFileImporter = false

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
                        session.connect(payload: payload)
                    },
                    onManual: { showScanner = false; showManual = true },
                    onClose: { showScanner = false })
            }
            .sheet(isPresented: $showManual) { manualConnectSheet }
            .sheet(isPresented: $showSettings) {
                SettingsView(settings: settings, savedHosts: savedHosts, onClose: { showSettings = false })
            }
            .sheet(item: Binding(get: { session.receivedFile }, set: { session.receivedFile = $0 })) { file in
                ReceivedFileSheet(file: file) { session.receivedFile = nil }
            }
            .sheet(isPresented: sasPairingPresented) {
                SASPairingSheet(session: session)
            }
            .onChange(of: session.status) { _, status in
                // Remember the host on first stream — for ALL paths — using the connection's resolved
                // concrete IP (so a QR/manual/saved/discovered pairing persists, and a moved Mac's IP
                // refreshes in place via SavedHostsStore's name-aware upsert).
                if status == .streaming, let payload = session.connectedHostToSave {
                    savedHosts.remember(payload)
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
                    session.reconnect(saved: saved, discovered: discovery.hosts)
                },
                onPickDiscovered: { host in
                    session.beginSASPairing(to: host)
                },
                onScan: { showScanner = true },
                onManual: { showManual = true },
                onSettings: { showSettings = true })
            .onAppear { discovery.start() }
            .onDisappear { discovery.stop() }
        }
    }

    private var sasPairingPresented: Binding<Bool> {
        Binding(get: { session.sasPairing != nil }, set: { if !$0 { session.cancelSASPairing() } })
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

/// Presents a file received from the Mac, with a share/save action.
private struct ReceivedFileSheet: View {
    let file: ReceivedFile
    let onDone: () -> Void

    var body: some View {
        GlassCanvas(style: .deck) {
            VStack(spacing: 18) {
                Spacer()
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Glass.signal)
                Text("Received from your Mac").font(.mono(10)).eyebrow(10).foregroundStyle(Glass.text2)
                Text(file.name)
                    .font(.grotesk(18, .semibold))
                    .foregroundStyle(Glass.text1Bright)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                ShareLink(item: file.url) {
                    Label("Save or share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(AccentButtonStyle())
                .padding(.horizontal, 40)
                Button("Done", action: onDone)
                    .font(.mono(11))
                    .foregroundStyle(Glass.text3)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(20)
        }
        .preferredColorScheme(.dark)
    }
}

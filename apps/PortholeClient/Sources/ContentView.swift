import SwiftUI

struct ContentView: View {
    @StateObject private var session = SessionViewModel()
    @State private var host = ""
    @State private var port = ""
    @State private var pin = ""

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
                    Section("Mac host") {
                        TextField("IP address", text: $host)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Port", text: $port)
                            .keyboardType(.numberPad)
                        TextField("Pin (64 hex chars)", text: $pin)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                    }
                    Section {
                        Button("Connect") {
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
            }
        }
    }
}

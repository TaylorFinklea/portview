import SwiftUI

/// Glass-styled settings sheet: stream quality (applied to the next connection's handshake — the
/// host honors it), saved-Mac management, and app info.
struct SettingsView: View {
    @ObservedObject var settings: ClientSettingsStore
    @ObservedObject var savedHosts: SavedHostsStore
    let onClose: () -> Void

    @State private var confirmForget = false

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }

    var body: some View {
        GlassCanvas(style: .deck) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    qualityCard
                    savedCard
                    aboutCard
                    Spacer(minLength: 0)
                }
                .padding(20)
            }
        }
        .preferredColorScheme(.dark)
        .alert("Forget all saved Macs?", isPresented: $confirmForget) {
            Button("Forget all", role: .destructive) { savedHosts.removeAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need to re-pair via QR or pin to reconnect.")
        }
    }

    private var header: some View {
        HStack {
            Text("Settings").font(.grotesk(26, .bold)).foregroundStyle(Glass.text1)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Glass.text2).frame(width: 30, height: 30)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
    }

    private var qualityCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Stream quality").eyebrow(10).foregroundStyle(Glass.text2)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Bitrate").font(.grotesk(14, .medium)).foregroundStyle(Glass.text1)
                    Spacer()
                    Text(settings.settings.bitrateMbps == 0 ? "Auto" : "\(settings.settings.bitrateMbps) Mbps")
                        .font(.mono(13, .semibold)).foregroundStyle(Glass.signal)
                }
                Slider(
                    value: Binding(
                        get: { Double(settings.settings.bitrateMbps) },
                        set: { settings.settings.bitrateMbps = Int($0.rounded()) }),
                    in: 0...Double(ClientSettings.bitrateRange.upperBound),
                    step: 1)
                    .tint(Glass.signal)
                Text("Auto lets the Mac pick a high bitrate. Higher = crisper text, more bandwidth. Applies on the next connection.")
                    .font(.mono(10)).foregroundStyle(Glass.text3)
            }

            HStack {
                Text("Frame rate").font(.grotesk(14, .medium)).foregroundStyle(Glass.text1)
                Spacer()
                ForEach(ClientSettings.fpsOptions, id: \.self) { option in
                    let on = settings.settings.fps == option
                    Button {
                        settings.settings.fps = option
                    } label: {
                        Text("\(option) fps")
                            .font(.mono(12, .semibold))
                            .foregroundStyle(on ? Glass.signalInk : Glass.text1)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background {
                                if on {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Glass.signal)
                                } else {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.white.opacity(0.06))
                                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(18)
        .glassCard()
    }

    private var savedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved Macs").eyebrow(10).foregroundStyle(Glass.text2)
            Text(savedHosts.hosts.isEmpty ? "No saved Macs." : "\(savedHosts.hosts.count) saved.")
                .font(.mono(12)).foregroundStyle(Glass.text2)
            Button { confirmForget = true } label: {
                Label("Forget all saved Macs", systemImage: "trash")
                    .font(.grotesk(13, .semibold)).foregroundStyle(Glass.dangerText)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(Glass.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Glass.danger.opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(savedHosts.hosts.isEmpty)
            .opacity(savedHosts.hosts.isEmpty ? 0.5 : 1)
        }
        .padding(18)
        .glassCard()
    }

    private var aboutCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Portview").font(.grotesk(15, .semibold)).foregroundStyle(Glass.text1)
                Text("iPhone → Mac screen share + control").font(.mono(10)).foregroundStyle(Glass.text2)
            }
            Spacer()
            Text(version).font(.mono(11)).foregroundStyle(Glass.text3)
        }
        .padding(18)
        .glassCard()
    }
}

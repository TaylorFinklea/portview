// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import PortviewTransport

/// Screen 1 — Deck Home. Pick a Mac to connect to (saved or freshly discovered) or start pairing.
/// Reachability is real: a saved Mac is "on this network" iff a Bonjour host matches it by name.
struct DeckHomeView: View {
    @ObservedObject var session: SessionViewModel
    @ObservedObject var discovery: DiscoveryModel
    @ObservedObject var savedHosts: SavedHostsStore
    /// One-time passive hint: notifications are denied, so background "ready to resume" re-wake
    /// alerts from a Mac can't appear. Informational only — nothing here is blocked.
    let showNotificationsHint: Bool
    let onReconnectSaved: (SavedHost) -> Void
    let onPickDiscovered: (DiscoveredHost) -> Void
    let onScan: () -> Void
    let onManual: () -> Void
    let onSettings: () -> Void

    /// Discovered hosts that aren't already saved (saved ones render from the store).
    private var newlyDiscovered: [DiscoveredHost] {
        discovery.hosts.filter { host in !savedHosts.hosts.contains { $0.name == host.name } }
    }
    private var totalMacs: Int { savedHosts.hosts.count + newlyDiscovered.count }
    private var onNetworkCount: Int {
        savedHosts.hosts.filter { $0.isOnNetwork(among: discovery.hosts) }.count + newlyDiscovered.count
    }

    var body: some View {
        GlassCanvas(style: .deck) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    scanStatus
                        .padding(.bottom, 8)

                    if showNotificationsHint {
                        Text("notifications are off — your Mac can't alert you when it's ready to resume")
                            .font(.mono(10))
                            .foregroundStyle(Glass.text3)
                            .padding(.bottom, 8)
                    }

                    ForEach(savedHosts.hosts) { saved in
                        let onNet = saved.isOnNetwork(among: discovery.hosts)
                        MacTile(
                            name: saved.name,
                            badge: "SAVED",
                            badgeStyle: .neutral,
                            dot: onNet ? .onNetwork : .offline,
                            subline: onNet ? "on this network · tap to resume"
                                            : "\(saved.host) : \(String(saved.port)) · off network",
                            accent: onNet,
                            action: { onReconnectSaved(saved) })
                    }

                    ForEach(newlyDiscovered) { host in
                        MacTile(
                            name: host.name,
                            badge: "NEW",
                            badgeStyle: .accent,
                            dot: .onNetwork,
                            subline: "on this network · tap to pair",
                            accent: false,
                            action: { onPickDiscovered(host) })
                    }

                    Button(action: onScan) {
                        Label("Scan QR to pair", systemImage: "qrcode.viewfinder")
                    }
                    .buttonStyle(AccentButtonStyle())
                    .padding(.top, 6)

                    Button(action: onManual) {
                        Text("enter IP · pin manually")
                            .font(.mono(10))
                            .foregroundStyle(Glass.text3)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.top, 6)

                    if case .failed(let message) = session.status {
                        Text(message)
                            .font(.mono(11))
                            .foregroundStyle(Glass.dangerText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Portview")
                .font(.grotesk(30, .bold))
                .tracking(-0.6)
                .foregroundStyle(Glass.text1)
            Spacer()
            if totalMacs > 0 {
                Text("\(totalMacs) Macs · \(onNetworkCount) on net")
                    .font(.mono(10))
                    .foregroundStyle(Glass.text3)
            }
            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Glass.text2)
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
    }

    private var scanStatus: some View {
        HStack(spacing: 6) {
            StatusDot(kind: .onNetwork, size: 6)
            Text("bonjour · scanning network")
                .font(.mono(10))
                .foregroundStyle(Glass.signal)
        }
    }
}

/// A single Mac tile on Deck Home.
private struct MacTile: View {
    let name: String
    let badge: String
    let badgeStyle: PillBadge.Style
    let dot: StatusDot.Kind
    let subline: String
    let accent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    HStack(spacing: 10) {
                        StatusDot(kind: dot)
                        Text(name)
                            .font(.grotesk(18, .semibold))
                            .foregroundStyle(accent ? Glass.text1Bright : Glass.text1)
                    }
                    Spacer()
                    PillBadge(text: badge, style: accent ? .accent : badgeStyle)
                }
                Text(subline)
                    .font(.mono(10))
                    .foregroundStyle(accent ? Glass.text1.opacity(0.75) : Glass.text2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: Glass.sheet, accent: accent)
        }
        .buttonStyle(.plain)
    }
}

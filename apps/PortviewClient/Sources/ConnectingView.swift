// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// Screen 3 — secure-handshake feedback while `SessionViewModel.status == .connecting`. The
/// three-step checklist is a visual treatment of that single state (the handshake genuinely runs
/// pin → QUIC → HEVC negotiation); the last step stays in-progress until streaming begins.
struct ConnectingView: View {
    let hostName: String
    /// Non-nil for EVERY connect attempt (review Finding B), not just pairing-driven ones — this
    /// device's own key fingerprint, for the human to compare if the Mac raises its enrollment
    /// prompt (design v2 step 2). The SAS path shows this on its own sheet instead, so it never
    /// surfaces here for `.sas`.
    var compareFingerprint: String? = nil
    /// Selects the card's copy. `.qr` (a genuinely pairing-driven connect) uses the imperative
    /// "Approve on the Mac" copy; `.reconnect` (manual entry / saved-host reconnect) uses soft "if
    /// the Mac asks" copy — it's only actionable if an enrollment prompt actually appears, which an
    /// already-enrolled device won't trigger.
    var compareSource: SessionViewModel.PairingSource? = nil
    let onCancel: () -> Void

    var body: some View {
        GlassCanvas(style: .deck) {
            VStack(spacing: 0) {
                Spacer()
                SpinnerRing(diameter: 108, lineWidth: 3, color: Glass.signal) {
                    Image(systemName: "display")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Glass.signal)
                }
                VStack(spacing: 6) {
                    Text("Connecting to \(hostName)")
                        .font(.grotesk(21, .bold))
                        .foregroundStyle(Glass.text1)
                    Text("secure channel · QUIC")
                        .font(.mono(10))
                        .foregroundStyle(Glass.signal)
                }
                .padding(.top, 26)

                Spacer()

                if let compareFingerprint {
                    VStack(spacing: 6) {
                        Text(compareHeadline)
                            .font(.mono(11))
                            .foregroundStyle(Glass.text2)
                            .multilineTextAlignment(.center)
                        Text(compareFingerprint)
                            .font(.mono(16, .semibold))
                            .foregroundStyle(Glass.text1Bright)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(14)
                    .glassPanel(accent: true)
                    .padding(.horizontal, 34)
                    .padding(.bottom, 14)
                }

                VStack(alignment: .leading, spacing: 11) {
                    checklistRow("pin verified", done: true)
                    checklistRow("QUIC channel up", done: true)
                    checklistRow("negotiating HEVC stream…", done: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .glassPanel(accent: true)
                .padding(.horizontal, 34)

                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.mono(10))
                        .foregroundStyle(Glass.text3)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                }
                .padding(.top, 24)
                .padding(.bottom, 30)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// `.reconnect` (manual/saved — not itself pairing-driven) gets soft, conditional copy so an
    /// ordinary already-enrolled reconnect (no prompt) doesn't read as alarming; every other source
    /// (a genuinely pairing-driven connect) keeps the imperative "Approve on the Mac" copy.
    private var compareHeadline: String {
        compareSource == .reconnect
            ? "If the Mac asks to pair this device, compare ALL FIVE groups:"
            : "Approve on the Mac — compare ALL FIVE groups:"
    }

    private func checklistRow(_ text: String, done: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                if done {
                    Circle().fill(Glass.signal).frame(width: 16, height: 16)
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Glass.signalInk)
                } else {
                    PulsingRing(diameter: 16, color: Glass.signal)
                }
            }
            Text(text)
                .font(.mono(11))
                .foregroundStyle(done ? Glass.text1 : Glass.text2)
        }
    }
}

/// A rotating ring spinner wrapping arbitrary center content.
struct SpinnerRing<Center: View>: View {
    var diameter: CGFloat
    var lineWidth: CGFloat
    var color: Color
    @ViewBuilder var center: Center
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .shadow(color: color.opacity(0.4), radius: 8)
                .rotationEffect(.degrees(spin ? 360 : 0))
            center
        }
        .frame(width: diameter, height: diameter)
        .onAppear {
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spin = true }
        }
    }
}

/// A small in-progress ring that pulses opacity (handshake step / scanning state).
struct PulsingRing: View {
    var diameter: CGFloat
    var color: Color
    @State private var on = false
    var body: some View {
        Circle()
            .strokeBorder(color, lineWidth: 2)
            .frame(width: diameter, height: diameter)
            .opacity(on ? 1 : 0.45)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

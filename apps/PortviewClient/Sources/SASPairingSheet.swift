// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import PortviewClientCore

/// 6-digit SAS pairing entry for a Bonjour-discovered Mac (replaces typing the 64-hex pin). The Mac
/// displays a code; the user types it here. A match means the cert the client captured really is the
/// Mac's (no interception) and the client re-dials pinned; a mismatch warns of possible interception.
struct SASPairingSheet: View {
    @ObservedObject var session: SessionViewModel
    @State private var entered = ""

    private var isSixDigits: Bool { entered.filter(\.isNumber).count == 6 }

    var body: some View {
        GlassCanvas(style: .deck) {
            VStack(spacing: 18) {
                Text("Pair with Mac")
                    .font(.grotesk(22, .bold))
                    .foregroundStyle(Glass.text1)

                // Code matched; the coordinator already tore its own state down (`sasPairing` is nil
                // here) and handed off to the pinned re-dial. Stay on this sheet — driven from
                // `enrollmentCompare`, not `sasPairing` — until the Mac resolves the enrollment
                // prompt (design v2 step 2).
                let postMatch = session.enrollmentCompareSource == .sas
                if postMatch, let compare = session.enrollmentCompare {
                    ProgressView().tint(Glass.text1)
                    Text("Approve on the Mac — compare ALL FIVE groups:")
                        .font(.mono(12)).foregroundStyle(Glass.text2)
                        .multilineTextAlignment(.center)
                    Text(compare)
                        .font(.mono(18, .semibold))
                        .foregroundStyle(Glass.text1Bright)
                } else {
                    switch session.sasPairing {
                    case .connecting, .none:
                        ProgressView().tint(Glass.text1)
                        Text("Connecting…").font(.mono(12)).foregroundStyle(Glass.text2)

                    case .awaitingCode:
                        Text("Enter the 6-digit code shown on the Mac.")
                            .font(.mono(12)).foregroundStyle(Glass.text2)
                            .multilineTextAlignment(.center)
                        TextField("000000", text: $entered)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.center)
                            .font(.mono(30))
                            .foregroundStyle(Glass.text1)
                            .textFieldStyle(.plain)
                            .padding(.vertical, 6)
                        Button("Pair") { session.submitSASCode(entered) }
                            .buttonStyle(.plain)
                            .font(.grotesk(16, .semibold))
                            .foregroundStyle(isSixDigits ? Glass.signalInk : Glass.text3)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: Glass.button, style: .continuous)
                                .fill(isSixDigits ? AnyShapeStyle(Glass.accentFill) : AnyShapeStyle(Color.white.opacity(0.06))))
                            .disabled(!isSixDigits)

                    case .mismatch:
                        Text("Codes didn't match — possible interception. Make sure you're pairing with the right Mac, then try again.")
                            .font(.mono(12)).foregroundStyle(Glass.dangerText)
                            .multilineTextAlignment(.center)

                    case .failed(let message):
                        Text(message)
                            .font(.mono(12)).foregroundStyle(Glass.dangerText)
                            .multilineTextAlignment(.center)
                    }
                }

                Button("Cancel") {
                    // Post-match, `cancelSASPairing()` has nothing left to tear down (the
                    // coordinator already handed off) — stopping the pinned re-dial/retry and
                    // clearing the card is `disconnect()`'s job.
                    if postMatch {
                        session.disconnect()
                    } else {
                        session.cancelSASPairing()
                    }
                }
                    .buttonStyle(.plain)
                    .font(.mono(12))
                    .foregroundStyle(Glass.text2)
            }
            .padding(28)
            .frame(maxWidth: 340)
        }
    }
}

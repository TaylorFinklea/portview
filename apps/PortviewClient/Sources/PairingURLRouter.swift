// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import PortviewProtocol
import PortviewTransport

/// Routing for `portview://pair?…` URLs delivered by the system (`onOpenURL`). A URL is untrusted
/// external input: it only ever yields a payload to *confirm*, never a connection.
enum PairingURLRouter {
    /// Parses with the one `PairingPayload(urlString:)` parser, and additionally rejects a pin
    /// `SessionViewModel` would reject (it requires 32 bytes), so a bad URL is a clean no-op rather
    /// than a `.failed` session state.
    static func payload(from url: URL) -> PairingPayload? {
        guard let payload = PairingPayload(urlString: url.absoluteString),
              let pin = Data(hexString: payload.pinHex), pin.count == 32 else { return nil }
        return payload
    }

    enum Decision: Equatable {
        /// Show the confirm prompt now.
        case prompt
        /// Hold the payload until the walkthrough / other presentations dismiss.
        case queue
        /// Drop it: a session is connecting, reconnecting or live and must never be replaced.
        case ignore
    }

    static func decision(sessionActive: Bool, presentationBlocking: Bool) -> Decision {
        if sessionActive { return .ignore }
        return presentationBlocking ? .queue : .prompt
    }
}

/// Inline tap-to-confirm shown on Deck Home for a pairing URL (same Glass styling as the QR
/// path's detected toast, but without claiming the pin was verified — it came from a link).
struct PairingURLPrompt: View {
    let payload: PairingPayload
    let onPair: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "link")
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(Glass.signalInk)
                .frame(width: 32, height: 32)
                .background(Glass.signal, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Pair with \(payload.name ?? payload.host)?")
                    .font(.grotesk(14, .semibold))
                    .foregroundStyle(Glass.text1Bright)
                    .lineLimit(1)
                Text("\(payload.host):\(payload.port) · from a link")
                    .font(.mono(9.5))
                    .foregroundStyle(Glass.text2)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onCancel) {
                Text("Cancel")
                    .font(.mono(10, .semibold))
                    .foregroundStyle(Glass.text2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
            }
            Button(action: onPair) {
                Text("Pair")
                    .font(.mono(10, .semibold))
                    .foregroundStyle(Glass.signalInk)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Glass.signal, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .glassPanel(accent: true)
    }
}

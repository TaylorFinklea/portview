// SPDX-License-Identifier: Apache-2.0
import SwiftUI

struct WalkthroughPage: Equatable {
    let symbol: String
    let eyebrow: String
    let title: String
    let body: String

    static let all: [WalkthroughPage] = [
        WalkthroughPage(
            symbol: "display",
            eyebrow: "Welcome",
            title: "See and control your Mac",
            body: "Portview mirrors and controls a Mac that is logged in. The stream runs only while the app is open on your iPhone; it does not keep streaming in the background."),
        WalkthroughPage(
            symbol: "qrcode.viewfinder",
            eyebrow: "Pairing",
            title: "Pair from the Mac",
            body: "Put your iPhone and Mac on the same local network or Tailscale, then open the pairing window on the Mac. Scanning the QR code is optional: you can enter the 6-digit code or connect manually instead."),
        WalkthroughPage(
            symbol: "lock.shield",
            eyebrow: "Access",
            title: "You stay in charge",
            body: "Screen and input are on for paired devices. Clipboard and file transfer are off until you enable them on the Mac, which asks its owner to authenticate. Re-wake is best-effort: if the app is open it reconnects directly; if it is in the background it posts a notification you tap to resume. It needs the same Apple ID and notifications allowed."),
    ]
}

/// First-run walkthrough. Shown once before Deck Home and re-openable from Settings. It never
/// requests camera or notification permission; those stay contextual to pairing.
struct FirstRunWalkthroughView: View {
    let onFinish: () -> Void

    @State private var index = 0
    private let pages = WalkthroughPage.all
    private var isLast: Bool { index == pages.count - 1 }

    var body: some View {
        GlassCanvas(style: .deck) {
            VStack(spacing: 20) {
                HStack {
                    Spacer()
                    Button("Skip", action: onFinish)
                        .font(.mono(12)).foregroundStyle(Glass.text2)
                        .accessibilityIdentifier("walkthrough.skip")
                }
                TabView(selection: $index) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { offset, page in
                        pageView(page).tag(offset)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                Button(isLast ? "Get started" : "Next") {
                    if isLast { onFinish() } else { withAnimation(Glass.panel) { index += 1 } }
                }
                .buttonStyle(AccentButtonStyle())
                .accessibilityIdentifier("walkthrough.next")
            }
            .padding(20)
        }
        .preferredColorScheme(.dark)
    }

    private func pageView(_ page: WalkthroughPage) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                Spacer(minLength: 24)
                Image(systemName: page.symbol)
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(Glass.signal)
                    .accessibilityHidden(true)
                Text(page.eyebrow).eyebrow(10).foregroundStyle(Glass.text2)
                Text(page.title)
                    .font(.grotesk(24, .bold)).foregroundStyle(Glass.text1Bright)
                    .multilineTextAlignment(.center)
                Text(page.body)
                    .font(.grotesk(15)).foregroundStyle(Glass.text1)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 32)
        }
    }
}

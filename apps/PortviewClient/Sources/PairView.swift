import SwiftUI
import PortviewTransport

/// Screen 2 — Pair · Scan QR. The real camera (`QRScannerView`) sits behind a glass viewfinder; on a
/// decodable `portview://pair?…` payload a detected toast offers to pair (wiring to the same
/// `PairingPayload` flow as before).
struct PairView: View {
    let onConnect: (PairingPayload) -> Void
    let onManual: () -> Void
    let onClose: () -> Void

    @State private var detected: PairingPayload?

    var body: some View {
        ZStack {
            QRScannerView { code in
                guard detected == nil, let payload = PairingPayload(urlString: code) else { return }
                withAnimation(Glass.panel) { detected = payload }
            }
            .ignoresSafeArea()

            // Keep the UI legible over a bright scene without hiding the camera.
            RadialGradient(
                gradient: Gradient(colors: [.clear, .black.opacity(0.55)]),
                center: .center, startRadius: 120, endRadius: 460)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                header
                Spacer()
                Viewfinder()
                    .frame(width: 220, height: 220)
                Spacer()
                if let detected {
                    DetectedToast(payload: detected) { onConnect(detected) }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.horizontal, 18)
                }
                Button(action: onManual) {
                    Text("enter IP · pin manually")
                        .font(.mono(10))
                        .foregroundStyle(Glass.text3)
                }
                .padding(.top, 18)
                .padding(.bottom, 30)
            }
        }
        .overlay(alignment: .topLeading) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Glass.text1)
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(.leading, 18)
            .padding(.top, 8)
        }
    }

    private var header: some View {
        VStack(spacing: 9) {
            Text("Pair with your Mac")
                .font(.grotesk(22, .bold))
                .foregroundStyle(Glass.text1)
            Text("Open Portview on your Mac and point the camera at the QR code it shows.")
                .font(.mono(10.5))
                .multilineTextAlignment(.center)
                .foregroundStyle(Glass.text2)
                .padding(.horizontal, 32)
        }
        .padding(.top, 70)
    }
}

/// The viewfinder: four signal corner brackets and a sweeping scan line.
private struct Viewfinder: View {
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                ForEach(0..<4, id: \.self) { corner in
                    Bracket()
                        .stroke(Glass.signal, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 34, height: 34)
                        .shadow(color: Glass.signal.opacity(0.5), radius: 8)
                        .rotationEffect(.degrees(Double(corner) * 90))
                        .position(cornerPoint(corner, in: side))
                }
                Rectangle()
                    .fill(LinearGradient(colors: [.clear, Glass.signal, .clear],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: 2)
                    .shadow(color: Glass.signal, radius: 8)
                    .padding(.horizontal, 8)
                    .offset(y: sweep ? side * 0.38 : -side * 0.38)
            }
            .frame(width: side, height: side)
            .onAppear {
                withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { sweep = true }
            }
        }
    }

    private func cornerPoint(_ corner: Int, in side: CGFloat) -> CGPoint {
        let inset: CGFloat = 17
        switch corner {
        case 0: return CGPoint(x: inset, y: inset)
        case 1: return CGPoint(x: side - inset, y: inset)
        case 2: return CGPoint(x: side - inset, y: side - inset)
        default: return CGPoint(x: inset, y: side - inset)
        }
    }
}

/// A single top-left corner bracket (rotated for the other three corners).
private struct Bracket: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.4))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

/// The "Mac found" detected toast with a Pair action.
private struct DetectedToast: View {
    let payload: PairingPayload
    let onPair: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(Glass.signalInk)
                .frame(width: 32, height: 32)
                .background(Glass.signal, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: Glass.signal.opacity(0.5), radius: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(payload.name ?? payload.host) found")
                    .font(.grotesk(14, .semibold))
                    .foregroundStyle(Glass.text1Bright)
                Text("\(payload.host) · pin verified")
                    .font(.mono(9.5))
                    .foregroundStyle(Glass.text2)
            }
            Spacer()
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

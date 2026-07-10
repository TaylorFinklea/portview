// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import PortviewProtocol

struct QualityHUD: View {
    let diagnostics: QualityDiagnostics
    let zoom: CGFloat
    let renderScale: CGFloat
    let frameViewport: CGRect
    let samplerMode: VideoSamplerMode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let host = diagnostics.host {
                line("Host", "\(format(host.fps)) fps  \(format(host.encodedMbps)) Mbps")
                line("Enc", "\(host.encoderWidth)x\(host.encoderHeight)  @\(host.configuredBitrate / 1_000_000) Mbps  \(format(host.averageEncodeMs)) ms")
                line("Host bpp", "\(formatBPP(hostBitsPerPixel(host)))  \(host.averageFrameBytes) B/f")
                line("Crop", rect(host))
            } else {
                line("Host", "waiting")
            }

            if diagnostics.frameWidth > 0 {
                line("Recv", "\(format(diagnostics.receivedFPS)) fps  \(format(diagnostics.receivedMbps)) Mbps")
                line("Client bpp", "\(formatBPP(diagnostics.bitsPerPixelPerFrame))  \(Int(diagnostics.averageFrameBytes.rounded())) B/f")
                line("Decode", "\(diagnostics.frameWidth)x\(diagnostics.frameHeight)  \(format(diagnostics.averageDecodeMs)) ms")
            } else {
                line("Recv", "waiting")
            }

            line("View", "\(format(Double(zoom)))x zoom  \(format(Double(renderScale)))x render  \(samplerMode.label)")
            line("Frame", frameRect(frameViewport))
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func line(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
        }
    }

    private func rect(_ stats: QualityStats) -> String {
        "x\(format(stats.viewportNormalizedX)) y\(format(stats.viewportNormalizedY)) w\(format(stats.viewportNormalizedW)) h\(format(stats.viewportNormalizedH))"
    }

    private func frameRect(_ rect: CGRect) -> String {
        "x\(format(rect.minX)) y\(format(rect.minY)) w\(format(rect.width)) h\(format(rect.height))"
    }

    private func hostBitsPerPixel(_ stats: QualityStats) -> Double {
        let pixels = max(1, Double(stats.encoderWidth) * Double(stats.encoderHeight))
        return Double(stats.averageFrameBytes) * 8.0 / pixels
    }

    private func format(_ value: CGFloat) -> String {
        format(Double(value))
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func formatBPP(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}

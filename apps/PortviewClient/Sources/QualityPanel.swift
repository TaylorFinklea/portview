import SwiftUI

/// The Glass HUD quality panel — four live telemetry stats over dark glass. All values are real
/// (`TelemetryReadout`); network latency isn't measured, so the slots are link / frame / decode /
/// encode rather than a fabricated "ms" latency.
struct QualityPanel: View {
    let diagnostics: QualityDiagnostics
    let displayLabel: String

    var body: some View {
        let readout = TelemetryReadout(diagnostics)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("QUALITY · \(displayLabel)")
                    .eyebrow(9)
                    .foregroundStyle(Glass.text2)
                Spacer()
                PillBadge(text: "HEVC", style: .accent)
            }
            HStack(alignment: .top, spacing: 18) {
                stat("LINK", readout.link, "Mb", hero: true)
                stat("FRAME", readout.frame, "fps")
                stat("DECODE", readout.decode, "ms")
                stat("ENCODE", readout.encode, "ms")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .glassPanel(accent: true)
    }

    private func stat(_ label: String, _ value: String, _ unit: String, hero: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.mono(8))
                .foregroundStyle(Glass.text2)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.grotesk(18, .bold))
                    .foregroundStyle(hero ? Glass.signal : Glass.text1)
                Text(unit)
                    .font(.system(size: 9))
                    .foregroundStyle(Glass.text2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

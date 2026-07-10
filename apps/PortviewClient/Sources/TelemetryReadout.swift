// SPDX-License-Identifier: Apache-2.0
import Foundation
import PortviewProtocol

/// Formats real `QualityDiagnostics` into the short strings shown on the live telemetry rail and the
/// Glass HUD quality panel. Network latency (RTT) is not measured anywhere in the app, so it is
/// intentionally absent rather than fabricated — the panel surfaces link / frame / decode / encode,
/// all of which come from real measurements.
struct TelemetryReadout {
    /// True once at least one frame has been received and measured.
    let hasData: Bool
    /// Received throughput, Mbps (client-measured).
    let link: String
    /// Received frame rate, fps (client-measured).
    let frame: String
    /// Average client decode time, ms.
    let decode: String
    /// Average host encode time, ms — "—" until the host's quality stats arrive.
    let encode: String

    private static let unavailable = "—"

    init(_ diagnostics: QualityDiagnostics) {
        hasData = diagnostics.frameWidth > 0
        link = hasData ? String(format: "%.1f", diagnostics.receivedMbps) : Self.unavailable
        frame = hasData ? String(format: "%.0f", diagnostics.receivedFPS) : Self.unavailable
        decode = hasData ? String(format: "%.1f", diagnostics.averageDecodeMs) : Self.unavailable
        if let host = diagnostics.host {
            encode = String(format: "%.1f", host.averageEncodeMs)
        } else {
            encode = Self.unavailable
        }
    }
}

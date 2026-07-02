import Foundation
import PortviewProtocol

enum VideoSamplerMode: String, Equatable {
    case linear
    case nearest

    var label: String {
        switch self {
        case .linear: "Linear"
        case .nearest: "Nearest"
        }
    }

    var next: VideoSamplerMode {
        switch self {
        case .linear: .nearest
        case .nearest: .linear
        }
    }
}

struct QualityDiagnostics: Equatable {
    var host: QualityStats?
    var frameWidth: UInt32 = 0
    var frameHeight: UInt32 = 0
    var receivedMbps: Double = 0
    var receivedFPS: Double = 0
    var averageFrameBytes: Double = 0
    var bitsPerPixelPerFrame: Double = 0
    var averageDecodeMs: Double = 0
    /// Frames the host sent but this client never decoded during the window (sequence gaps).
    var droppedFrames: Int = 0
}

struct QualityDiagnosticsTracker {
    private var hostStats: QualityStats?
    private var windowStart = ProcessInfo.processInfo.systemUptime
    private var frames = 0
    private var bytes = 0
    private var decodeMsTotal = 0.0
    private var dropped = 0
    private var lastSequence: UInt64?
    private var latestWidth: UInt32 = 0
    private var latestHeight: UInt32 = 0
    private var latest = QualityDiagnostics()

    mutating func updateHostStats(_ stats: QualityStats) -> QualityDiagnostics {
        hostStats = stats
        latest.host = stats
        return latest
    }

    mutating func recordDecodedFrame(_ frame: VideoFrame, decodeMs: Double) -> QualityDiagnostics? {
        frames += 1
        bytes += frame.data.count
        decodeMsTotal += decodeMs
        // A gap in the host's monotonic sequence = frames sent but never decoded here. A sequence
        // going backwards (a new stream after a display switch) is a restart, not a drop.
        if let last = lastSequence, frame.sequence > last + 1 {
            dropped += Int(frame.sequence - last - 1)
        }
        lastSequence = frame.sequence
        latestWidth = frame.width
        latestHeight = frame.height

        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - windowStart
        guard elapsed >= 1.0, frames > 0 else { return nil }

        let pixels = max(1, Double(latestWidth) * Double(latestHeight))
        let averageBytes = Double(bytes) / Double(frames)
        latest = QualityDiagnostics(
            host: hostStats,
            frameWidth: latestWidth,
            frameHeight: latestHeight,
            receivedMbps: (Double(bytes) * 8.0 / elapsed) / 1_000_000.0,
            receivedFPS: Double(frames) / elapsed,
            averageFrameBytes: averageBytes,
            bitsPerPixelPerFrame: (averageBytes * 8.0) / pixels,
            averageDecodeMs: decodeMsTotal / Double(frames),
            droppedFrames: dropped
        )

        windowStart = now
        frames = 0
        bytes = 0
        decodeMsTotal = 0
        dropped = 0
        return latest
    }
}

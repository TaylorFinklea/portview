// SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreGraphics
import PortviewProtocol

struct QualityStatsAccumulator {
    private var windowStart = ProcessInfo.processInfo.systemUptime
    private var frames = 0
    private var encodedBytes = 0
    private var keyframes = 0
    private var encodeMsTotal = 0.0

    mutating func recordFrame(byteCount: Int, isKeyframe: Bool, encodeMs: Double) {
        frames += 1
        encodedBytes += byteCount
        if isKeyframe { keyframes += 1 }
        encodeMsTotal += encodeMs
    }

    mutating func snapshotIfDue(
        displayID: UInt32,
        encoderWidth: Int,
        encoderHeight: Int,
        configuredBitrate: Int,
        viewport: CGRect
    ) -> QualityStats? {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - windowStart
        guard elapsed >= 1.0, frames > 0 else { return nil }

        let stats = QualityStats(
            displayID: displayID,
            encoderWidth: UInt32(max(0, encoderWidth)),
            encoderHeight: UInt32(max(0, encoderHeight)),
            configuredBitrate: UInt32(max(0, configuredBitrate)),
            encodedMbpsX100: UInt32(max(0, ((Double(encodedBytes) * 8.0 / elapsed) / 1_000_000.0 * 100.0).rounded())),
            fpsX100: UInt32(max(0, (Double(frames) / elapsed * 100.0).rounded())),
            averageFrameBytes: UInt32(max(0, (Double(encodedBytes) / Double(frames)).rounded())),
            keyframes: UInt32(max(0, keyframes)),
            averageEncodeMsX100: UInt32(max(0, (encodeMsTotal / Double(frames) * 100.0).rounded())),
            viewportX: Self.unitToUInt16(viewport.minX),
            viewportY: Self.unitToUInt16(viewport.minY),
            viewportW: Self.unitToUInt16(viewport.width),
            viewportH: Self.unitToUInt16(viewport.height)
        )

        windowStart = now
        frames = 0
        encodedBytes = 0
        keyframes = 0
        encodeMsTotal = 0
        return stats
    }

    private static func unitToUInt16(_ value: CGFloat) -> UInt16 {
        UInt16((Double(min(1, max(0, value))) * 65535.0).rounded())
    }
}

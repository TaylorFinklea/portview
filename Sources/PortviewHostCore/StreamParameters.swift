// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Clamps the client's requested stream parameters (`StartSession`) into safe host ranges. The host
/// honors these instead of hardcoding 60 fps + a width·height bitrate heuristic, so the client's
/// quality settings actually take effect.
public enum StreamParameters {
    static let fpsRange = 10...60
    static let bitrateRange = 2_000_000...120_000_000

    /// Capture frame rate, clamped. A `requested` of 0 means "unset" → the 60 fps default.
    public static func captureFPS(requested: UInt16) -> Int {
        guard requested != 0 else { return fpsRange.upperBound }
        return min(fpsRange.upperBound, max(fpsRange.lowerBound, Int(requested)))
    }

    /// Encoder average bitrate (bits/s), clamped. A `requested` of 0 means "unset" → `nil`, so the
    /// encoder falls back to its width·height heuristic.
    public static func encoderBitrate(requested: UInt32) -> Int? {
        guard requested != 0 else { return nil }
        return min(bitrateRange.upperBound, max(bitrateRange.lowerBound, Int(requested)))
    }
}

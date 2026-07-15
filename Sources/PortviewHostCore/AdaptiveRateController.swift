// SPDX-License-Identifier: Apache-2.0
import Foundation
import PortviewProtocol

/// Pure adaptive bitrate/fps policy for a live session: maps the client's receive-side feedback
/// (`ClientFeedback`, tag 29) plus the host's own encode/throughput stats to the next target
/// bitrate and capture fps. Deterministic — the next targets are a function of the inputs and this
/// value's accumulated streak state (no clocks, no media) — so the policy unit-tests without a
/// live stream. The video pump applies the outputs each `QualityStats` interval via the encoder's
/// live `setAverageBitRate` (no session rebuild) and the capture's SCStream fps reconfigure.
///
/// Only steers in Auto mode (the client's `targetBitrate == 0` sentinel → host heuristic). When
/// the user pinned an explicit bitrate, the controller holds it untouched — never fight an
/// explicit choice.
///
/// Hysteresis: only a SUSTAINED bad signal (consecutive fresh intervals) steps bitrate down
/// multiplicatively; once bitrate is floored, fps sheds instead. Recovery steps up slowly after a
/// longer healthy streak — fps restored first (undoing the most recent cut), then bitrate — and is
/// bounded by the setpoint/ceiling, so a healthy steady state sits still instead of oscillating.
/// Outputs never leave `StreamParameters`' ranges.
///
/// Crop boost (bead 90p): when the capture is cropped (high zoom), the setpoint scales by inverse
/// crop area (capped) so the visible region's bits per pixel RISES with zoom instead of shrinking
/// with the buffer — crisper zoomed text. Auto mode only, and composed with congestion: the boost
/// moves the setpoint, never the step-down floor, so a congested link at high zoom still sheds.
struct AdaptiveRateController {
    enum Mode: Equatable {
        /// Client requested Auto (`targetBitrate == 0`): the host steers within clamps.
        case auto
        /// The user pinned an explicit bitrate; hold it untouched.
        case pinned
    }

    /// One stats interval's signals, grouped so future inputs can be added without churning
    /// `evaluate`'s signature.
    struct Inputs {
        /// Latest client receive-side snapshot; `nil` until the first `ClientFeedback` arrives.
        var feedback: ClientFeedback?
        /// The host's encode-side stats for the same interval.
        var hostStats: QualityStats?
        /// The SNAPPED normalized area of the display the capture is cropped to
        /// (`CaptureEngine.currentViewport()` width × height); 1.0 = full frame.
        var cropFraction: Double

        init(feedback: ClientFeedback?, hostStats: QualityStats? = nil, cropFraction: Double = 1.0) {
            self.feedback = feedback
            self.hostStats = hostStats
            self.cropFraction = cropFraction
        }
    }

    struct Targets: Equatable {
        var bitrate: Int
        var fps: Int
    }

    // Signal thresholds. RTT uses a two-band hysteresis (bad above `rttBadMicros`, healthy below
    // `rttGoodMicros`, hold in between) so a link hovering near a single cutoff can't oscillate.
    static let dropThreshold: UInt32 = 3
    static let rttBadMicros: UInt32 = 200_000
    static let rttGoodMicros: UInt32 = 100_000
    static let queueBadDepth: UInt16 = 4
    // Throughput deficit: the client receiving well under what the host encoded means the network
    // is queueing, even before drops surface. Only meaningful at non-trivial encode rates (a
    // static screen encodes almost nothing, and the two 1s windows aren't perfectly aligned).
    static let deficitFloorMbps = 5.0
    static let deficitRatio = 0.6
    // Step limits: fast multiplicative decrease, slow bounded increase (classic AIMD shape). The
    // streak lengths are the hysteresis — one bad or good interval alone never moves anything.
    static let badIntervalsBeforeStepDown = 2
    static let goodIntervalsBeforeStepUp = 3
    static let downStepFactor = 0.7
    static let upStepFactor = 1.15
    static let upStepMinimum = 1_000_000
    static let fpsStep = 10
    // Crop boost cap. Inverse area exactly cancels the width·height shrink of a rebuilt cropped
    // encoder's bitrate heuristic — the visible region keeps the full-frame budget, so bits per
    // pixel rises with zoom. The cap bounds the demand at extreme zoom: past ~4× the buffer has
    // already shrunk far more than the boost, so bits per pixel is way up regardless, and an
    // uncapped inverse would burn link headroom for no visible gain.
    static let maxCropBoost = 4.0

    private let mode: Mode
    /// Base recovery ceiling for bitrate: the encoder's starting rate (heuristic in Auto),
    /// clamped. The crop boost scales this into `effectiveSetpoint`.
    private let bitrateSetpoint: Int
    /// Recovery ceiling for fps: the client's requested capture rate, clamped.
    private let fpsCeiling: Int
    private var bitrate: Int
    private var fps: Int
    private var cropBoost = 1.0
    private var badStreak = 0
    private var goodStreak = 0
    private var lastFeedback: ClientFeedback?

    /// Recovery/steady-state ceiling for bitrate with the crop boost applied, inside the clamps.
    private var effectiveSetpoint: Int {
        Self.clampBitrate(Int((Double(bitrateSetpoint) * cropBoost).rounded()))
    }

    /// `initialCropFraction` seeds the crop boost at construction (bead s86): an encoder rebuild
    /// at a zoom-rung crossing recreates the controller, and without the seed the cropped region
    /// encodes at the unboosted heuristic until the next stats interval re-applies the boost.
    /// Auto mode only, like every boost path; 1.0 (full frame) reproduces the unseeded behavior.
    init(mode: Mode, bitrateSetpoint: Int, fpsCeiling: Int, initialCropFraction: Double = 1.0) {
        self.mode = mode
        self.bitrateSetpoint = min(StreamParameters.bitrateRange.upperBound,
                                   max(StreamParameters.bitrateRange.lowerBound, bitrateSetpoint))
        self.fpsCeiling = min(StreamParameters.fpsRange.upperBound,
                              max(StreamParameters.fpsRange.lowerBound, fpsCeiling))
        bitrate = self.bitrateSetpoint
        fps = self.fpsCeiling
        if mode == .auto {
            applyCropBoost(initialCropFraction)
        }
    }

    /// The targets currently in force, without folding new signals — what a caller applies right
    /// after (re)seeding, before the first stats interval reaches `evaluate`.
    var currentTargets: Targets { Targets(bitrate: bitrate, fps: fps) }

    /// Fold one stats interval's signals into the streak state and return the next targets.
    mutating func evaluate(_ inputs: Inputs) -> Targets {
        guard mode == .auto else { return Targets(bitrate: bitrate, fps: fps) }
        // The crop boost folds BEFORE the fresh-feedback gate: a zoom is a host-side event, so it
        // must retarget even on an interval with no (or stale) client feedback.
        applyCropBoost(inputs.cropFraction)
        // An unchanged snapshot is NOT a fresh signal (the holder re-serves the latest one when
        // the client goes quiet); re-counting it would turn one bad second into "sustained".
        guard let feedback = inputs.feedback, feedback != lastFeedback else {
            return Targets(bitrate: bitrate, fps: fps)
        }
        lastFeedback = feedback

        if isBad(feedback, hostStats: inputs.hostStats) {
            goodStreak = 0
            badStreak += 1
            if badStreak >= Self.badIntervalsBeforeStepDown {
                badStreak = 0  // hold off: a step needs a fresh sustained streak to repeat
                stepDown()
            }
        } else if isGood(feedback) {
            badStreak = 0
            goodStreak += 1
            if goodStreak >= Self.goodIntervalsBeforeStepUp {
                goodStreak = 0
                stepUp()
            }
        } else {
            // Neutral (e.g. RTT between the bands): hold, and reset both streaks so only
            // genuinely sustained signals move the targets.
            badStreak = 0
            goodStreak = 0
        }
        return Targets(bitrate: bitrate, fps: fps)
    }

    private func isBad(_ feedback: ClientFeedback, hostStats: QualityStats?) -> Bool {
        if feedback.droppedFrames >= Self.dropThreshold { return true }
        if feedback.rttMicros >= Self.rttBadMicros { return true }  // 0 = unmeasured, never bad
        if feedback.decodeQueueDepth >= Self.queueBadDepth { return true }
        if let hostStats, hostStats.encodedMbps >= Self.deficitFloorMbps,
           feedback.receivedMbps < hostStats.encodedMbps * Self.deficitRatio { return true }
        return false
    }

    private func isGood(_ feedback: ClientFeedback) -> Bool {
        feedback.droppedFrames == 0
            && (feedback.rttMicros == 0 || feedback.rttMicros <= Self.rttGoodMicros)
            && feedback.decodeQueueDepth <= 1
    }

    /// Shed bitrate first (fps is what makes remote control feel live); only once bitrate is
    /// floored does fps shed. Both stop at the `StreamParameters` floors.
    private mutating func stepDown() {
        if bitrate > StreamParameters.bitrateRange.lowerBound {
            bitrate = max(StreamParameters.bitrateRange.lowerBound,
                          Int(Double(bitrate) * Self.downStepFactor))
        } else if fps > StreamParameters.fpsRange.lowerBound {
            fps = max(StreamParameters.fpsRange.lowerBound, fps - Self.fpsStep)
        }
    }

    /// Recover in reverse: restore fps first (undoing the most recent cut), then grow bitrate
    /// slowly back toward — never past — the (crop-boosted) setpoint.
    private mutating func stepUp() {
        if fps < fpsCeiling {
            fps = min(fpsCeiling, fps + Self.fpsStep)
        } else if bitrate < effectiveSetpoint {
            bitrate = min(effectiveSetpoint,
                          max(bitrate + Self.upStepMinimum, Int(Double(bitrate) * Self.upStepFactor)))
        }
    }

    /// Fold the capture crop fraction into the operating point. On a boost change the live
    /// bitrate rescales PROPORTIONALLY — its attenuation as a fraction of the setpoint carries
    /// across — so a healthy stream jumps straight to the boosted setpoint (crisp immediately,
    /// no slow step-up) while a congested one stays equally attenuated: the boost moves the
    /// setpoint, and congestion keeps stepping down to the unscaled `stepDown` floor.
    private mutating func applyCropBoost(_ fraction: Double) {
        let boost = Self.cropBoost(forFraction: fraction)
        guard boost != cropBoost else { return }
        let priorSetpoint = effectiveSetpoint
        cropBoost = boost
        bitrate = Self.clampBitrate(
            Int((Double(bitrate) * Double(effectiveSetpoint) / Double(priorSetpoint)).rounded()))
    }

    /// Inverse-area boost for a cropped capture, capped by `maxCropBoost`. Degenerate fractions
    /// (≤ 0, or ≥ 1 = full frame) mean no boost.
    static func cropBoost(forFraction fraction: Double) -> Double {
        guard fraction > 0, fraction < 1 else { return 1 }
        return min(maxCropBoost, 1 / fraction)
    }

    private static func clampBitrate(_ bps: Int) -> Int {
        min(StreamParameters.bitrateRange.upperBound,
            max(StreamParameters.bitrateRange.lowerBound, bps))
    }
}

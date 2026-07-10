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
struct AdaptiveRateController {
    enum Mode: Equatable {
        /// Client requested Auto (`targetBitrate == 0`): the host steers within clamps.
        case auto
        /// The user pinned an explicit bitrate; hold it untouched.
        case pinned
    }

    /// One stats interval's signals, grouped so future inputs (e.g. the capture crop fraction,
    /// bead 90p) can be added without churning `evaluate`'s signature.
    struct Inputs {
        /// Latest client receive-side snapshot; `nil` until the first `ClientFeedback` arrives.
        var feedback: ClientFeedback?
        /// The host's encode-side stats for the same interval.
        var hostStats: QualityStats?

        init(feedback: ClientFeedback?, hostStats: QualityStats? = nil) {
            self.feedback = feedback
            self.hostStats = hostStats
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

    private let mode: Mode
    /// Recovery ceiling for bitrate: the encoder's starting rate (heuristic in Auto), clamped.
    private let bitrateSetpoint: Int
    /// Recovery ceiling for fps: the client's requested capture rate, clamped.
    private let fpsCeiling: Int
    private var bitrate: Int
    private var fps: Int
    private var badStreak = 0
    private var goodStreak = 0
    private var lastFeedback: ClientFeedback?

    init(mode: Mode, bitrateSetpoint: Int, fpsCeiling: Int) {
        self.mode = mode
        self.bitrateSetpoint = min(StreamParameters.bitrateRange.upperBound,
                                   max(StreamParameters.bitrateRange.lowerBound, bitrateSetpoint))
        self.fpsCeiling = min(StreamParameters.fpsRange.upperBound,
                              max(StreamParameters.fpsRange.lowerBound, fpsCeiling))
        bitrate = self.bitrateSetpoint
        fps = self.fpsCeiling
    }

    /// Fold one stats interval's signals into the streak state and return the next targets.
    mutating func evaluate(_ inputs: Inputs) -> Targets {
        guard mode == .auto else { return Targets(bitrate: bitrate, fps: fps) }
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
    /// slowly back toward — never past — the setpoint.
    private mutating func stepUp() {
        if fps < fpsCeiling {
            fps = min(fpsCeiling, fps + Self.fpsStep)
        } else if bitrate < bitrateSetpoint {
            bitrate = min(bitrateSetpoint,
                          max(bitrate + Self.upStepMinimum, Int(Double(bitrate) * Self.upStepFactor)))
        }
    }
}

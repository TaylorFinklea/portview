// SPDX-License-Identifier: Apache-2.0
import Testing
import PortviewProtocol
@testable import PortviewHostCore

/// Pure adaptive bitrate/fps policy (bead 480): sustained bad client feedback steps bitrate DOWN
/// within `StreamParameters` clamps, recovery steps UP slowly and bounded, a healthy steady state
/// sits still, and an explicit user-pinned bitrate is never fought. The crop boost (bead 90p)
/// raises the setpoint by inverse area at high zoom — clamped, composed with congestion, and
/// never applied to a pinned bitrate.
@Suite struct AdaptiveRateControllerTests {
    private let setpoint = 40_000_000

    private func autoController(setpoint: Int? = nil, fps: Int = 60) -> AdaptiveRateController {
        AdaptiveRateController(mode: .auto, bitrateSetpoint: setpoint ?? self.setpoint, fpsCeiling: fps)
    }

    /// A per-interval client snapshot. `tick` perturbs `receivedFPSX100` so consecutive snapshots
    /// are distinct, the way real 1s windows are (an unchanged snapshot means "no fresh signal").
    private func feedback(tick: UInt32, drops: UInt32 = 0, rttMicros: UInt32 = 20_000,
                          queueDepth: UInt16 = 0, receivedMbps: Double = 20) -> ClientFeedback {
        ClientFeedback(
            receivedFPSX100: 5_900 + tick,
            receivedMbpsX100: UInt32((receivedMbps * 100).rounded()),
            averageDecodeMsX100: 400,
            decodeQueueDepth: queueDepth,
            droppedFrames: drops,
            rttMicros: rttMicros)
    }

    private func hostStats(encodedMbps: Double = 20) -> QualityStats {
        QualityStats(
            displayID: 1, encoderWidth: 1920, encoderHeight: 1080,
            configuredBitrate: UInt32(setpoint),
            encodedMbpsX100: UInt32((encodedMbps * 100).rounded()),
            fpsX100: 6_000, averageFrameBytes: 40_000, keyframes: 1, averageEncodeMsX100: 300,
            viewportX: 0, viewportY: 0, viewportW: 65_535, viewportH: 65_535)
    }

    @Test func holdsSetpointBeforeAnyFeedbackArrives() {
        var controller = autoController()
        for _ in 0..<5 {
            let targets = controller.evaluate(AdaptiveRateController.Inputs(feedback: nil))
            #expect(targets == AdaptiveRateController.Targets(bitrate: setpoint, fps: 60))
        }
    }

    @Test func sustainedDropsStepBitrateDown() {
        var controller = autoController()

        // One bad interval alone is not "sustained" — no step yet (hysteresis).
        let first = controller.evaluate(.init(feedback: feedback(tick: 1, drops: 10)))
        #expect(first.bitrate == setpoint)

        let second = controller.evaluate(.init(feedback: feedback(tick: 2, drops: 12)))
        #expect(second.bitrate == Int(Double(setpoint) * AdaptiveRateController.downStepFactor))
        #expect(second.bitrate >= StreamParameters.bitrateRange.lowerBound)
        #expect(second.fps == 60)  // bitrate sheds first; fps only once bitrate is floored
    }

    @Test func sustainedHighRTTStepsBitrateDown() {
        var controller = autoController()
        _ = controller.evaluate(.init(feedback: feedback(tick: 1, rttMicros: 250_000)))
        let targets = controller.evaluate(.init(feedback: feedback(tick: 2, rttMicros: 260_000)))
        #expect(targets.bitrate < setpoint)
    }

    @Test func sustainedDeepDecodeQueueStepsBitrateDown() {
        var controller = autoController()
        _ = controller.evaluate(.init(feedback: feedback(tick: 1, queueDepth: 8)))
        let targets = controller.evaluate(.init(feedback: feedback(tick: 2, queueDepth: 9)))
        #expect(targets.bitrate < setpoint)
    }

    @Test func sustainedThroughputDeficitStepsBitrateDown() {
        // Client receives well under what the host encoded → the network is queueing, even
        // before drops surface.
        var controller = autoController()
        _ = controller.evaluate(.init(feedback: feedback(tick: 1, receivedMbps: 5), hostStats: hostStats(encodedMbps: 20)))
        let targets = controller.evaluate(.init(feedback: feedback(tick: 2, receivedMbps: 5), hostStats: hostStats(encodedMbps: 21)))
        #expect(targets.bitrate < setpoint)
    }

    @Test func staleFeedbackIsNotReCounted() {
        // The holder re-serves the latest snapshot; an unchanged one must not accrue "sustained".
        var controller = autoController()
        let stale = feedback(tick: 1, drops: 10)
        for _ in 0..<5 {
            let targets = controller.evaluate(.init(feedback: stale))
            #expect(targets.bitrate == setpoint)
        }
    }

    @Test func intermittentBadSignalDoesNotStep() {
        // Bad intervals separated by neutral ones (RTT between the good/bad bands) never step:
        // the streak resets, so only genuinely sustained congestion reacts.
        var controller = autoController()
        for tick in 0..<8 {
            let fb = tick.isMultiple(of: 2)
                ? feedback(tick: UInt32(tick), drops: 10)
                : feedback(tick: UInt32(tick), rttMicros: 150_000)
            let targets = controller.evaluate(.init(feedback: fb))
            #expect(targets.bitrate == setpoint)
        }
    }

    @Test func healthySteadyStateIsStable() {
        var controller = autoController()
        for tick in 1...10 {
            let targets = controller.evaluate(.init(feedback: feedback(tick: UInt32(tick)), hostStats: hostStats()))
            #expect(targets == AdaptiveRateController.Targets(bitrate: setpoint, fps: 60))
        }
    }

    @Test func recoveryStepsUpSlowlyBoundedBySetpoint() {
        var controller = autoController()
        for tick in 1...4 {  // two step-downs: 40 → 28 → 19.6 Mbps
            _ = controller.evaluate(.init(feedback: feedback(tick: UInt32(tick), drops: 10)))
        }
        var previous = controller.evaluate(.init(feedback: feedback(tick: 5)))
        #expect(previous.bitrate < setpoint)

        for tick in 6...40 {
            let targets = controller.evaluate(.init(feedback: feedback(tick: UInt32(tick))))
            #expect(targets.bitrate >= previous.bitrate)  // recovery never dips
            let allowed = max(Int(Double(previous.bitrate) * AdaptiveRateController.upStepFactor),
                              previous.bitrate + AdaptiveRateController.upStepMinimum)
            #expect(targets.bitrate <= allowed)  // each step is bounded
            #expect(targets.bitrate <= setpoint)  // never overshoots the setpoint
            #expect(targets.fps == 60)
            previous = targets
        }
        #expect(previous.bitrate == setpoint)  // full recovery lands exactly back on the setpoint
    }

    @Test func flooredBitrateShedsFPSAndNeverLeavesClamps() {
        var controller = autoController(setpoint: 4_000_000)
        var last = AdaptiveRateController.Targets(bitrate: 4_000_000, fps: 60)
        for tick in 1...60 {
            last = controller.evaluate(.init(feedback: feedback(tick: UInt32(tick), drops: 10)))
            #expect(StreamParameters.bitrateRange.contains(last.bitrate))
            #expect(StreamParameters.fpsRange.contains(last.fps))
        }
        // Terminal state under unrelenting congestion: both floored, holding steady.
        #expect(last == AdaptiveRateController.Targets(
            bitrate: StreamParameters.bitrateRange.lowerBound,
            fps: StreamParameters.fpsRange.lowerBound))
    }

    @Test func recoveryRestoresFPSFirstBoundedByCeiling() {
        // Drive to the floor with a 30fps ceiling, then recover: fps is restored first (the most
        // recent cut) and only up to the requested ceiling, never the global 60.
        var controller = autoController(setpoint: 4_000_000, fps: 30)
        for tick in 1...60 {
            _ = controller.evaluate(.init(feedback: feedback(tick: UInt32(tick), drops: 10)))
        }
        var sawFPSRecoverFirst = false
        var last = AdaptiveRateController.Targets(bitrate: 0, fps: 0)
        for tick in 61...120 {
            last = controller.evaluate(.init(feedback: feedback(tick: UInt32(tick))))
            #expect(last.fps <= 30)
            if last.fps < 30 {
                // While fps is still recovering, bitrate must not move yet.
                #expect(last.bitrate == StreamParameters.bitrateRange.lowerBound)
                sawFPSRecoverFirst = true
            }
        }
        #expect(sawFPSRecoverFirst)
        #expect(last == AdaptiveRateController.Targets(bitrate: 4_000_000, fps: 30))
    }

    @Test func initClampsSetpointsToStreamParameterRanges() {
        var high = AdaptiveRateController(mode: .auto, bitrateSetpoint: 500_000_000, fpsCeiling: 240)
        #expect(high.evaluate(.init(feedback: nil)) == AdaptiveRateController.Targets(
            bitrate: StreamParameters.bitrateRange.upperBound,
            fps: StreamParameters.fpsRange.upperBound))

        var low = AdaptiveRateController(mode: .auto, bitrateSetpoint: 1, fpsCeiling: 1)
        #expect(low.evaluate(.init(feedback: nil)) == AdaptiveRateController.Targets(
            bitrate: StreamParameters.bitrateRange.lowerBound,
            fps: StreamParameters.fpsRange.lowerBound))
    }

    @Test func pinnedModeNeverTouchesBitrate() {
        // The user pinned an explicit bitrate (bitrateMbps != 0 → targetBitrate != 0): the
        // controller must not fight it, no matter how bad the feedback looks.
        var controller = AdaptiveRateController(mode: .pinned, bitrateSetpoint: 8_000_000, fpsCeiling: 60)
        for tick in 1...10 {
            let targets = controller.evaluate(.init(
                feedback: feedback(tick: UInt32(tick), drops: 50, rttMicros: 400_000, queueDepth: 10),
                hostStats: hostStats()))
            #expect(targets == AdaptiveRateController.Targets(bitrate: 8_000_000, fps: 60))
        }
    }

    // MARK: Crop boost (bead 90p)

    @Test func bitrateRisesAsCropFractionFallsBoundedByClamps() {
        var controller = autoController(setpoint: 20_000_000)
        // The boost needs no fresh client feedback: zooming alone raises the target.
        let zoomed = controller.evaluate(.init(feedback: nil, cropFraction: 0.64))
        #expect(zoomed.bitrate == 31_250_000)  // 20 Mbps ÷ 0.64
        let deeper = controller.evaluate(.init(feedback: nil, cropFraction: 0.25))
        #expect(deeper.bitrate == 80_000_000)  // 20 Mbps ÷ 0.25
        // Inverse-area is capped: an extreme crop holds at maxCropBoost, not 1/area (uncapped,
        // 20 Mbps ÷ 0.05 would have hit the 120 Mbps clamp instead).
        let extreme = controller.evaluate(.init(feedback: nil, cropFraction: 0.05))
        #expect(extreme.bitrate == 20_000_000 * Int(AdaptiveRateController.maxCropBoost))
        #expect(extreme.fps == 60)  // the boost never touches fps

        // And the boosted target never leaves the StreamParameters clamps.
        var wide = autoController()  // 40 Mbps setpoint × 4 would be 160 Mbps
        let clamped = wide.evaluate(.init(feedback: nil, cropFraction: 0.1))
        #expect(clamped.bitrate == StreamParameters.bitrateRange.upperBound)
    }

    @Test func fullFrameCropFractionLeavesBehaviorUnchanged() {
        // Explicit fraction 1.0 must be byte-identical to the pre-90p healthy steady state.
        var controller = autoController()
        for tick in 1...10 {
            let targets = controller.evaluate(.init(
                feedback: feedback(tick: UInt32(tick)), hostStats: hostStats(), cropFraction: 1.0))
            #expect(targets == AdaptiveRateController.Targets(bitrate: setpoint, fps: 60))
        }
    }

    @Test func pinnedBitrateIsNeverBoosted() {
        var controller = AdaptiveRateController(mode: .pinned, bitrateSetpoint: 8_000_000, fpsCeiling: 60)
        for tick in 1...5 {
            let targets = controller.evaluate(.init(
                feedback: feedback(tick: UInt32(tick)), cropFraction: 0.1))
            #expect(targets == AdaptiveRateController.Targets(bitrate: 8_000_000, fps: 60))
        }
    }

    @Test func congestionStillStepsDownAtHighZoom() {
        var controller = autoController(setpoint: 20_000_000)
        let boosted = controller.evaluate(.init(feedback: nil, cropFraction: 0.25))
        #expect(boosted.bitrate == 80_000_000)

        // Sustained congestion at high zoom steps down from the BOOSTED operating point.
        _ = controller.evaluate(.init(feedback: feedback(tick: 1, drops: 10), cropFraction: 0.25))
        let stepped = controller.evaluate(.init(feedback: feedback(tick: 2, drops: 12), cropFraction: 0.25))
        #expect(stepped.bitrate == Int(Double(boosted.bitrate) * AdaptiveRateController.downStepFactor))

        // Unrelenting congestion drives all the way to the GLOBAL floor: the boost scales the
        // setpoint, never the stepDown floor.
        var last = stepped
        for tick in 3...80 {
            last = controller.evaluate(.init(
                feedback: feedback(tick: UInt32(tick), drops: 10), cropFraction: 0.25))
            #expect(StreamParameters.bitrateRange.contains(last.bitrate))
        }
        #expect(last.bitrate == StreamParameters.bitrateRange.lowerBound)
    }

    @Test func zoomDuringCongestionPreservesAttenuationAndRecoversToBoostedSetpoint() {
        var controller = autoController(setpoint: 10_000_000)
        _ = controller.evaluate(.init(feedback: feedback(tick: 1, drops: 10)))
        let congested = controller.evaluate(.init(feedback: feedback(tick: 2, drops: 12)))
        #expect(congested.bitrate == 7_000_000)  // one full-frame step down

        // Zooming in mid-congestion scales the whole operating point: the attenuation (70% of
        // the setpoint) carries across, so the boost never erases congestion state.
        let zoomed = controller.evaluate(.init(feedback: nil, cropFraction: 0.25))
        #expect(zoomed.bitrate == 28_000_000)  // 70% of the boosted 40 Mbps setpoint

        // Sustained health then recovers up to the BOOSTED setpoint — and never past it.
        var last = zoomed
        for tick in 3...60 {
            last = controller.evaluate(.init(feedback: feedback(tick: UInt32(tick)), cropFraction: 0.25))
            #expect(last.bitrate <= 40_000_000)
        }
        #expect(last.bitrate == 40_000_000)
    }

    @Test func zoomBackOutReturnsToTheBaseSetpoint() {
        var controller = autoController(setpoint: 20_000_000)
        #expect(controller.evaluate(.init(feedback: nil, cropFraction: 0.25)).bitrate == 80_000_000)
        #expect(controller.evaluate(.init(feedback: nil, cropFraction: 1.0)).bitrate == 20_000_000)
    }

    // MARK: Boost-aware reseed (bead s86)

    @Test func reseedWithCropFractionStartsAtTheBoostedSetpoint() {
        // An encoder rebuild at a zoom-rung crossing recreates the controller. Seeding it with the
        // frame's crop fraction must apply the boost IMMEDIATELY — not one stats interval later —
        // so the cropped region never encodes at the unboosted heuristic while zoomed.
        let controller = AdaptiveRateController(
            mode: .auto, bitrateSetpoint: 20_000_000, fpsCeiling: 60, initialCropFraction: 0.25)
        #expect(controller.currentTargets == AdaptiveRateController.Targets(bitrate: 80_000_000, fps: 60))
    }

    @Test func reseedBoostIsCappedAndClamped() {
        let extreme = AdaptiveRateController(
            mode: .auto, bitrateSetpoint: 20_000_000, fpsCeiling: 60, initialCropFraction: 0.05)
        #expect(extreme.currentTargets.bitrate == 20_000_000 * Int(AdaptiveRateController.maxCropBoost))

        let wide = AdaptiveRateController(
            mode: .auto, bitrateSetpoint: 40_000_000, fpsCeiling: 60, initialCropFraction: 0.1)
        #expect(wide.currentTargets.bitrate == StreamParameters.bitrateRange.upperBound)
    }

    @Test func reseedFullFrameAndDefaultAreUnchanged() {
        // Full frame (1.0) and the defaulted parameter are byte-identical to the pre-s86 seed.
        let full = AdaptiveRateController(
            mode: .auto, bitrateSetpoint: setpoint, fpsCeiling: 60, initialCropFraction: 1.0)
        #expect(full.currentTargets == AdaptiveRateController.Targets(bitrate: setpoint, fps: 60))
        #expect(autoController().currentTargets == AdaptiveRateController.Targets(bitrate: setpoint, fps: 60))
    }

    @Test func reseedNeverBoostsAPinnedBitrate() {
        let pinned = AdaptiveRateController(
            mode: .pinned, bitrateSetpoint: 8_000_000, fpsCeiling: 60, initialCropFraction: 0.1)
        #expect(pinned.currentTargets == AdaptiveRateController.Targets(bitrate: 8_000_000, fps: 60))
    }

    @Test func seededBoostComposesWithLaterEvaluate() {
        // The seeded boost is the same state evaluate() maintains: staying at the same crop is a
        // no-op, zooming back out returns to the base setpoint, congestion still sheds.
        var controller = AdaptiveRateController(
            mode: .auto, bitrateSetpoint: 20_000_000, fpsCeiling: 60, initialCropFraction: 0.25)
        #expect(controller.evaluate(.init(feedback: nil, cropFraction: 0.25)).bitrate == 80_000_000)
        #expect(controller.evaluate(.init(feedback: nil, cropFraction: 1.0)).bitrate == 20_000_000)
    }
}

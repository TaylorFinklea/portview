// SPDX-License-Identifier: Apache-2.0
import Testing
import PortviewClientCore

/// Deterministic generator (Knuth's MMIX LCG), so every simulated run replays exactly.
private struct SeededLCG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    /// A 31-bit draw, uniform over `0..<2^31`.
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 33
    }
}

/// How late a buffer arrives beyond its nominal time.
private enum ArrivalJitter {
    /// Every buffer arrives on its nominal time.
    case none
    /// Uniform over `0...maxMicros`.
    case uniform(maxMicros: Int64)
    /// Quantile-matched to the device log's steady-state delay above the session's best: p50 22.4 ms,
    /// p99 51.6 ms, p99.9 86.6 ms, max 149.9 ms. This is a piecewise-linear inverse CDF through those
    /// points, so the body and the tail both match the measurements.
    case field

    func micros(from draw: UInt64) -> Int64 {
        switch self {
        case .none:
            return 0
        case .uniform(let maxMicros):
            return maxMicros > 0 ? Int64(draw % UInt64(maxMicros + 1)) : 0
        case .field:
            return Self.fieldQuantile(Double(draw) / 2_147_483_648)
        }
    }

    /// (cumulative probability, delay in µs) through the measured quantiles.
    private static let fieldAnchors: [(probability: Double, micros: Double)] = [
        (0.0, 0.0), (0.5, 22_400), (0.99, 51_600), (0.999, 86_600), (0.9999, 149_900), (1.0, 150_000),
    ]

    static func fieldQuantile(_ u: Double) -> Int64 {
        for (low, high) in zip(fieldAnchors, fieldAnchors.dropFirst()) where u < high.probability {
            let t = (u - low.probability) / (high.probability - low.probability)
            return Int64(low.micros + t * (high.micros - low.micros))
        }
        return 150_000
    }

    /// P(delay > micros) under the same piecewise-linear distribution.
    static func fieldTailProbability(aboveMicros x: Double) -> Double {
        for (low, high) in zip(fieldAnchors, fieldAnchors.dropFirst()) where x < high.micros {
            let fraction = (max(x, low.micros) - low.micros) / (high.micros - low.micros)
            return 1 - (low.probability + fraction * (high.probability - low.probability))
        }
        return 0
    }
}

/// A 20 ms stream fed to ``AudioPlayoutScheduler`` on a deterministic clock, with the render position
/// modelled on the device as the log measured it.
///
/// - The PTS steps exactly 20,000 µs per 960-frame buffer at 48 kHz.
/// - Each buffer arrives at its nominal time plus jitter and any injected stall, never before the buffer
///   queued ahead of it.
/// - The player renders in 1,024-frame cycles. Cycle `k` starts at sample `1024·k`, at local time `r_k`,
///   which runs at the effective rate `48 · (1 + drift·1e-6)` samples per ms. At arrival time `t`, the
///   render position is the latest cycle with `r_k ≤ t`: `S = 1024·(k+1)` (±1 sample of seeded noise when
///   enabled) and `H = r_k + 45 ms`, since that sample is heard 45 ms after its cycle starts.
/// - Samples below `S + 1024` are committed. The oracle in these tests is that no plan starts below that
///   boundary, measured against the true `S`.
private struct PlayoutSimulation {
    static let framesPerBuffer = 960
    static let pts0: Int64 = 252_837_861_436
    static let arrival0: Int64 = 384_246_805_410
    /// The player starts 1 ms before the first buffer arrives.
    static let playerStartMicros: Int64 = PlayoutSimulation.arrival0 - 1_000

    /// The clock the integrator would use: host = local + offset, with the default 50 ms headroom.
    static func clock() -> PresentationClock {
        PresentationClock(hostClockOffsetMicros: pts0 - arrival0)
    }

    var driftPPM = 0.0
    var jitter: ArrivalJitter = .none
    /// Extra arrival delay for a buffer index. Buffers queued behind it bunch up.
    var stalls: [Int: Int64] = [:]
    /// Buffers of PTS skipped before a buffer index: a source discontinuity with no arrival stall.
    var ptsSkips: [Int: Int] = [:]
    /// When true the reported `S` carries ±1 sample of seeded noise. The committed boundary used by the
    /// oracle is always the true `S`, so noise cannot hide a violation.
    var renderNoise = true
    /// Arrivals drift later relative to PTS at this rate (slow clock drift between sender and receiver).
    var arrivalDriftPPM = 0.0
    /// From this buffer index on, every arrival is delayed by `sustainedDelayMicros` (a sustained step).
    var sustainedDelayFrom: Int?
    var sustainedDelayMicros: Int64 = 0
    var seed: UInt64 = 0x5EED_0001
    var configuration = AudioPlayoutScheduler.Configuration(sampleRate: 48_000)
    /// Frames the simulated route commits per render cycle (1,024 on Roshar's speaker; larger on some routes).
    var renderCycleFrames: Int64 = 1_024
    /// Render-to-ear latency of the simulated route: `H` is this far after the cycle starts (45 ms = Roshar's speaker).
    var outputLatencyMicros: Double = 45_000
    /// Added to every clock target, as the integrator does with `AudioRouteLatency.compensationMicros`.
    var targetCompensationMicros: Int64 = 0

    struct Record {
        let index: Int
        let pts: UInt64
        /// Arrival if the buffer had no jitter and no stall: `arrival0 + (pts − pts0)`.
        let nominal: Int64
        /// The active presentation clock's nominal for this PTS: `pts − clockOffset`. It equals `nominal` until
        /// the clock is re-anchored, and the explained-underrun check measures lateness against it.
        let clockNominal: Int64
        let arrival: Int64
        let target: Int64
        /// The render position the scheduler saw (may carry noise).
        let render: AudioRenderPosition
        /// True `S + 1024`: samples below this are committed at the moment of arrival.
        let committedEnd: Int64
        let plan: AudioPlayoutPlan?
        /// Adaptive lead in force after this buffer.
        let extraLeadMicros: Int64
        /// Underruns counted so far, including this buffer.
        let underrunsSoFar: Int
        /// The scheduler asked for a clock re-anchor after this buffer (the harness rebuilds the clock next).
        let clockReanchorRequested: Bool
    }

    /// Feeds `buffers` buffers through a fresh scheduler and records every decision.
    func run(buffers: Int) -> (records: [Record], stats: AudioPlayoutStats) {
        var clockOffset = Self.pts0 - Self.arrival0
        var clock = PresentationClock(hostClockOffsetMicros: clockOffset)
        var rebuildClockNext = false
        var scheduler = AudioPlayoutScheduler(configuration: configuration)
        var rng = SeededLCG(seed: seed)
        var previousArrival = Int64.min
        var skipped = 0
        var records: [Record] = []
        records.reserveCapacity(buffers)
        let samplesPerMicro = 0.048 * (1 + driftPPM * 1e-6)
        for index in 0..<buffers {
            skipped += ptsSkips[index] ?? 0
            let pts = UInt64(Self.pts0 + 20_000 * Int64(index + skipped))
            let nominal = Self.arrival0 + (Int64(pts) - Self.pts0)
            let jitterDraw = rng.next()
            let noiseDraw = Int64(rng.next() % 3) - 1
            let drift = Int64((Double(nominal - Self.arrival0) * arrivalDriftPPM * 1e-6).rounded())
            let sustained = (sustainedDelayFrom.map { index >= $0 } ?? false) ? sustainedDelayMicros : 0
            let arrival = max(previousArrival, nominal + jitter.micros(from: jitterDraw)
                                + (stalls[index] ?? 0) + drift + sustained)
            previousArrival = arrival
            // The integrator discards its clock when the scheduler asks, and this buffer re-anchors it at
            // offset = pts − arrival, the same rule as the initial anchor. The scheduler is NOT reset: the player
            // keeps its queue, and taking the request already unanchored the schedule.
            if rebuildClockNext {
                clockOffset = Int64(pts) - arrival
                clock = PresentationClock(hostClockOffsetMicros: clockOffset)
                rebuildClockNext = false
            }

            let elapsedSamples = Double(arrival - Self.playerStartMicros) * samplesPerMicro
            let cycle = Int64((elapsedSamples / Double(renderCycleFrames)).rounded(.down))
            let cycleStartMicros = Double(Self.playerStartMicros)
                + Double(renderCycleFrames) * Double(cycle) / samplesPerMicro
            let trueS = renderCycleFrames * (cycle + 1)
            let render = AudioRenderPosition(
                hostMicros: Int64((cycleStartMicros + outputLatencyMicros).rounded()),
                sampleTime: trueS + (renderNoise ? noiseDraw : 0),
                cycleFrames: renderCycleFrames)

            let target = clock.targetPresentTimeMicros(forPTSMicros: pts) + targetCompensationMicros
            let plan = scheduler.plan(ptsMicros: pts, frames: Self.framesPerBuffer,
                                      targetMicros: target, render: render)
            let reanchorRequested = scheduler.takeClockReanchorRequest()
            if reanchorRequested {
                rebuildClockNext = true
            }
            records.append(Record(index: index, pts: pts, nominal: nominal,
                                  clockNominal: Int64(pts) - clockOffset, arrival: arrival, target: target,
                                  render: render, committedEnd: trueS + renderCycleFrames, plan: plan,
                                  extraLeadMicros: scheduler.stats.extraLeadMicros,
                                  underrunsSoFar: scheduler.stats.underruns,
                                  clockReanchorRequested: reanchorRequested))
        }
        return (records, scheduler.stats)
    }
}

/// The frame the clock wants a buffer at, with an explicit adaptive lead (µs). The scheduler's own
/// ideal start is this with `lead` set to the lead in force.
private func idealStart(_ record: PlayoutSimulation.Record, lead: Int64) -> Int64 {
    let delta = Double(record.target - record.render.hostMicros) + Double(lead)
    return record.render.sampleTime + Int64((delta * 48_000 / 1_000_000).rounded())
}

/// Placement boundaries of the shipped per-buffer scheme (no lead): consecutive buffers whose own
/// idealStart is not exactly one buffer (960 frames) after the previous one.
private func oldPlacementBoundaries(_ records: [PlayoutSimulation.Record]) -> Int {
    zip(records, records.dropFirst())
        .filter { idealStart($1, lead: 0) != idealStart($0, lead: 0) + 960 }
        .count
}

/// The oracle. No returned plan may start in audio the player has already committed (samples below the
/// true `S + 1024`), nor inside audio already queued by an earlier plan (the simulation never stops the player,
/// so nothing queued is ever withdrawn). A violation is a policy bug to fix in the scheduler, never a reason to
/// relax this.
private func expectNoPlanInCommittedAudio(_ records: [PlayoutSimulation.Record]) {
    let violations = records.compactMap { record -> Int? in
        guard let plan = record.plan, plan.startSample < record.committedEnd else { return nil }
        return record.index
    }
    #expect(violations.isEmpty, "plans placed in committed audio at buffers \(violations.prefix(5))")
    var queuedEnd = Int64.min
    var overlaps: [Int] = []
    for record in records {
        guard let plan = record.plan else { continue }
        if plan.startSample < queuedEnd { overlaps.append(record.index) }
        queuedEnd = plan.startSample + Int64(plan.outputFrames)
    }
    #expect(overlaps.isEmpty, "plans overlapping queued audio at buffers \(overlaps.prefix(5))")
    // A recovery shorter than one crossfade would cut its fade-in short and click into its successor.
    let shortRecoveries = records.compactMap { record -> Int? in
        guard let plan = record.plan, case .resync = plan.edit,
              plan.outputFrames < AudioPlayoutScheduler.Configuration(sampleRate: 48_000).crossfadeFrames
        else { return nil }
        return record.index
    }
    #expect(shortRecoveries.isEmpty, "recoveries shorter than a crossfade at buffers \(shortRecoveries.prefix(5))")
    // Guard against a vacuous pass: the oracle says nothing about a run where almost nothing was planned.
    let planned = records.filter { $0.plan != nil }.count
    #expect(planned * 2 > records.count, "only \(planned) of \(records.count) buffers were planned")
}

/// Whether buffer `index` triggered an underrun recovery.
private func isUnderrun(_ records: [PlayoutSimulation.Record], at index: Int) -> Bool {
    records[index].underrunsSoFar > (index == 0 ? 0 : records[index - 1].underrunsSoFar)
}

private func underrunIndices(_ records: [PlayoutSimulation.Record]) -> [Int] {
    records.indices.filter { isUnderrun(records, at: $0) }
}

/// Expected underruns from arrivals later than the lead's reach, with no drift and the field jitter.
/// At a steady lead `L` a buffer underruns when its lateness exceeds `L − 25 ms + phase`, where `phase` is
/// uniform over one 21.33 ms render cycle. The expectation is the field tail beyond that threshold,
/// averaged over the phase.
private func expectedCeilingUnderruns(buffers: Int, ceilingMicros: Double) -> Double {
    let phases = 64
    let meanTail = (0..<phases).map { i -> Double in
        let phase = 21_333.33 * (Double(i) + 0.5) / Double(phases)
        return ArrivalJitter.fieldTailProbability(aboveMicros: ceilingMicros - 25_000 + phase)
    }.reduce(0, +) / Double(phases)
    return Double(buffers) * meanTail
}

/// Every underrun must be explained by arrival lateness the lead could not cover. The underrun test is
/// `nextSample < S + minLead`. With the grid and the ideal aligned, that fires only when
///
///     lateness > leadBefore − 25 ms + phase + err
///
/// where `phase ∈ [0, 21.3 ms)` is the arrival's offset into its render cycle, and `err` is the schedule
/// error. In steady state `|err| ≤ band` plus about 1 ms of trigger overshoot. So an underrun needs
/// `lateness > leadBefore − 25 ms − band − 1 ms`. Lateness is the true arrival minus the nominal time,
/// so bunching behind a stall counts as lateness.
private func expectUnderrunsExplained(_ records: [PlayoutSimulation.Record], initialLead: Int64, band: Int64) {
    for index in records.indices where isUnderrun(records, at: index) {
        let leadBefore = index == 0 ? initialLead : records[index - 1].extraLeadMicros
        let lateness = records[index].arrival - records[index].clockNominal
        let floor = leadBefore - 25_000 - band - 1_000
        #expect(lateness > floor, "underrun at buffer \(index): lateness \(lateness) µs, floor \(floor) µs")
    }
}

/// Indices of planned buffers that do not abut their planned predecessor
/// (`start != previousStart + previousOutputFrames`).
private func contiguityBreaks(_ records: [PlayoutSimulation.Record]) -> [Int] {
    var breaks: [Int] = []
    var previous: AudioPlayoutPlan?
    for record in records {
        guard let plan = record.plan else { continue }
        if let previous, plan.startSample != previous.startSample + Int64(previous.outputFrames) {
            breaks.append(record.index)
        }
        previous = plan
    }
    return breaks
}

private func isResync(_ record: PlayoutSimulation.Record) -> Bool {
    guard let edit = record.plan?.edit else { return false }
    if case .resync = edit { return true }
    return false
}

/// Contiguity holds everywhere except at a counted re-anchor.
private func expectContiguityOnlyAtResyncs(_ records: [PlayoutSimulation.Record]) {
    let resyncIndices = Set(records.filter(isResync).map(\.index))
    let unexplained = contiguityBreaks(records).filter { !resyncIndices.contains($0) }
    #expect(unexplained.isEmpty, "contiguity breaks that are not resyncs: \(unexplained.prefix(5))")
}

/// Schedule error in µs (positive = late) for every contiguous plan, measured against the clock with the
/// lead in force for that buffer. Resync plans re-anchor and are excluded, which is the "outside resync
/// events" scope the splice bound applies to.
private func contiguousErrorsMicros(_ records: [PlayoutSimulation.Record]) -> [Int64] {
    records.compactMap { record -> Int64? in
        guard let plan = record.plan else { return nil }
        switch plan.edit {
        case .none, .skip, .repeatHead:
            let frames = plan.startSample - idealStart(record, lead: record.extraLeadMicros)
            return Int64((Double(frames) * 1_000_000 / 48_000).rounded())
        case .resync:
            return nil
        }
    }
}

/// Every splice the run produced, in order, as its edit.
private func splices(_ records: [PlayoutSimulation.Record]) -> [AudioSpliceEdit] {
    records.compactMap { record -> AudioSpliceEdit? in
        guard let edit = record.plan?.edit else { return nil }
        switch edit {
        case .skip, .repeatHead: return edit
        case .none, .resync: return nil
        }
    }
}

/// Feeds one buffer of a clean stream on a zero-offset clock. Buffer `index` arrives exactly on time,
/// and the render position sits exactly on the grid (`sample = arrival · 48 / 1000`).
/// `feedCleanBuffer` with a PTS gap added before this buffer (µs, shifting its PTS and target together) and a
/// shift of the clock target alone (µs; negative = the clock wants it earlier, so the queued schedule runs late).
private func feedShiftedBuffer(_ scheduler: inout AudioPlayoutScheduler, index: Int, ptsGap: Int64 = 0,
                               targetShift: Int64) -> AudioPlayoutPlan? {
    let arrival = 1_000_000 + 20_000 * Int64(index)
    let render = AudioRenderPosition(hostMicros: arrival, sampleTime: arrival * 48 / 1_000)
    return scheduler.plan(ptsMicros: UInt64(arrival + ptsGap), frames: 960,
                          targetMicros: arrival + ptsGap + 50_000 + targetShift, render: render)
}

private func feedCleanBuffer(_ scheduler: inout AudioPlayoutScheduler, index: Int) -> AudioPlayoutPlan? {
    let arrival = 1_000_000 + 20_000 * Int64(index)
    let render = AudioRenderPosition(hostMicros: arrival, sampleTime: arrival * 48 / 1_000)
    return scheduler.plan(ptsMicros: UInt64(arrival), frames: 960,
                          targetMicros: arrival + 50_000, render: render)
}

@Suite struct AudioPlayoutSchedulerTests {
    private let band: Int64 = 8_000
    private let maxSplice: Int64 = 5_000
    private let initialLead: Int64 = 40_000

    /// (a) The field case: the iPhone renders at +10.9 ppm, with the measured arrival jitter, for 10 min.
    /// The oracle holds, every underrun is explained by lateness the lead could not cover, contiguity
    /// holds except at counted resyncs, and the adaptive lead stays within its ceiling.
    @Test func fieldCaseHoldsTheCommittedRegionAndUnderrunsOnlyAsTheLeadAdapts() {
        var sim = PlayoutSimulation()
        sim.driftPPM = 10.9
        sim.jitter = .field
        sim.seed = 0xF1E1_D000
        let buffers = 10 * 60 * 50
        let (records, stats) = sim.run(buffers: buffers)

        expectNoPlanInCommittedAudio(records)
        expectUnderrunsExplained(records, initialLead: initialLead, band: band)
        expectContiguityOnlyAtResyncs(records)
        #expect(stats.extraLeadMicros == 120_000, "lead \(stats.extraLeadMicros) µs")

        // Re-anchors from isolated jitter-tail underruns at the ceiling are measured over several seeds in the field
        // case test below. This test covers the lead's climb and the underrun count.

        // The lead climbs 40 → 120 ms in four steps, one per underrun. From the ceiling on, only arrivals
        // later than the ceiling can reach underrun, so each post-warm-up underrun sits at the ceiling and
        // their count matches the field tail beyond it. A ≤3 total is not reachable at this ceiling.
        let underruns = underrunIndices(records)
        let warmUp = 3_000
        let early = underruns.filter { $0 < warmUp }
        let late = underruns.filter { $0 >= warmUp }
        let expectedEarly = expectedCeilingUnderruns(buffers: warmUp, ceilingMicros: 120_000)
        #expect(Double(early.count) <= 4 + 2 * expectedEarly + 1,
                "early underruns \(early.count): 4 lead steps plus about \(expectedEarly) tail arrivals")
        #expect(late.allSatisfy { records[$0 - 1].extraLeadMicros == 120_000 },
                "a post-warm-up underrun below the ceiling: \(late.prefix(10))")
        let expectedLate = expectedCeilingUnderruns(buffers: buffers - warmUp, ceilingMicros: 120_000)
        #expect(Double(late.count) >= expectedLate / 2 && Double(late.count) <= 2 * expectedLate,
                "post-warm-up underruns \(late.count), expected about \(expectedLate) from the tail beyond the ceiling")

        let worst = contiguousErrorsMicros(records).map { abs($0) }.max() ?? 0
        #expect(worst <= band + maxSplice, "worst error \(worst) µs")
    }

    /// (b) Regression for the shipped bug. Placing every buffer at its own rounded idealStart slips with
    /// the clock drift: at +10.9 ppm the accumulated drift crosses a whole frame about every 96 buffers
    /// (960.01046 frames per buffer), so placement boundaries land throughout the minute.
    ///
    /// Render noise and jitter also move the per-buffer placement, so the drift attribution uses a
    /// noise-free, jitter-free run with a zero-drift twin as the baseline. The contiguous scheduler
    /// produces no placement boundaries on that same run.
    @Test func shippedPerBufferPlacementSlipsWithDriftWhileTheContiguousScheduleDoesNot() {
        var drifted = PlayoutSimulation()
        drifted.driftPPM = 10.9
        drifted.renderNoise = false
        let (driftedRecords, driftedStats) = drifted.run(buffers: 60 * 50)

        var still = drifted
        still.driftPPM = 0
        let (stillRecords, _) = still.run(buffers: 60 * 50)

        // The drift alone accumulates about 31 whole frames in 60 s (3000 × 960 × 10.9e-6). The
        // cycle-quantized render position adds more rounding boundaries on top, so the measured count
        // (49 in this model) is above that. The assertion is the spec's bound, not an exact count.
        let oldDrifted = oldPlacementBoundaries(driftedRecords)
        #expect(oldDrifted >= 20, "drifted per-buffer placement produced \(oldDrifted) boundaries")
        #expect(oldPlacementBoundaries(stillRecords) == 0,
                "zero drift must not slip: \(oldPlacementBoundaries(stillRecords)) boundaries")
        #expect(contiguityBreaks(driftedRecords).isEmpty)
        #expect(driftedStats.splices == 0)
        expectNoPlanInCommittedAudio(driftedRecords)
        expectNoPlanInCommittedAudio(stillRecords)
        #expect(stillRecords.allSatisfy { $0.plan != nil }, "every zero-drift buffer must be planned")
        #expect(driftedRecords.allSatisfy { $0.plan != nil }, "every drifted buffer must be planned")
    }

    /// (c) Long drift, both signs: one hour at ±50 ppm with uniform 0–30 ms of jitter.
    ///
    /// Sign. The player renders faster than PTS at +ppm, so its sample index outruns the clock while the
    /// contiguous schedule advances a fixed 960 per buffer. The error (`start − idealStart`) falls, the
    /// audio runs early, and the scheduler responds with `.repeatHead`. At −ppm the error grows positive
    /// (late) and the scheduler responds with `.skip`. The spec's parenthetical had these reversed, and
    /// the definitions give this mapping.
    ///
    /// Splice bound. Drift to absorb is D = |ppm| · 1 h = 180 ms. Each splice removes at most maxSplice
    /// (5 ms), and the residual error when the run ends is at most band (8 ms), so at least
    /// ⌈(D − band) / maxSplice⌉ = ⌈172 / 5⌉ = 35 splices are needed. Upward, a correction episode starts
    /// when the error exceeds band and ends at zero: the first splice takes 8 → 3 ms, and the second
    /// removes the rest, so an episode is at most two splices. Per episode, the drift that re-triggers one
    /// is at least `band`, so at most ⌈D / band⌉ = 23 episodes start, giving ≤ 2·23 + 2 = 48.
    @Test(arguments: [50.0, -50.0])
    func hourLongDriftIsAbsorbedBySplicesInTheRightDirection(driftPPM: Double) {
        var sim = PlayoutSimulation()
        sim.driftPPM = driftPPM
        sim.jitter = .uniform(maxMicros: 30_000)
        sim.seed = 0xD21F_7001
        let (records, stats) = sim.run(buffers: 3_600 * 50)

        expectNoPlanInCommittedAudio(records)
        expectUnderrunsExplained(records, initialLead: initialLead, band: band)
        expectContiguityOnlyAtResyncs(records)

        // Lead steps are needed to cover arrival jitter: lead − 25 ms − (error bottom) ≥ 30 ms (max jitter).
        // At −ppm the error stays ≥ 0 (late), so the lead must reach 55 ms: one step, to 60 ms. At +ppm the
        // error sawtooths to about −band = −8 ms, so the lead must reach 63 ms: two steps, to 80 ms. The
        // second step at +ppm lands about two minutes in, when the error first reaches its band bottom. So
        // underruns are one per lead step, and the lead is still adapting for that long.
        let expectedFinalLead: Int64 = driftPPM > 0 ? 80_000 : 60_000
        let underruns = underrunIndices(records)
        #expect(stats.extraLeadMicros == expectedFinalLead, "lead \(stats.extraLeadMicros) µs at \(driftPPM) ppm")
        #expect(underruns.count == Int((expectedFinalLead - initialLead) / 20_000),
                "underruns \(underruns) at \(driftPPM) ppm: one per lead step")

        let worstError = contiguousErrorsMicros(records).map { abs($0) }.max() ?? 0
        #expect(worstError <= band + maxSplice, "worst error \(worstError) µs outside resync events")

        let all = splices(records)
        let skips = all.filter { if case .skip = $0 { true } else { false } }.count
        let repeats = all.filter { if case .repeatHead = $0 { true } else { false } }.count
        if driftPPM > 0 {
            #expect(skips == 0, "+ppm must only repeat the head, skips \(skips)")
        } else {
            #expect(repeats == 0, "−ppm must only skip the head, repeats \(repeats)")
        }
        let maxFrames = 240  // fr(5 ms) at 48 kHz
        var oversized = 0
        for edit in all {
            switch edit {
            case .skip(let frames), .repeatHead(let frames):
                if frames < 1 || frames > maxFrames { oversized += 1 }
            case .none, .resync:
                break
            }
        }
        #expect(oversized == 0, "\(oversized) splices outside 1…\(maxFrames) frames")

        #expect(all.count >= 35 && all.count <= 48, "splice count \(all.count), derived bound [35, 48]")
    }

    /// (d) Jitter just inside the lead's reach: uniform 0–35 ms with no drift, for 10 min. At the initial
    /// 40 ms lead, a buffer 15 ms or more late can underrun. One step (to 60 ms) covers every arrival, since
    /// lateness ≤ 35 ms and the underrun needs lateness > lead − 25 ms + phase ≥ 35 ms. So exactly one
    /// underrun, one lead step, and none afterwards.
    @Test func jitterWithinTheLeadsReachCostsOneUnderrunAndOneStep() {
        var sim = PlayoutSimulation()
        sim.jitter = .uniform(maxMicros: 35_000)
        sim.seed = 0x4A17_0040
        let (records, stats) = sim.run(buffers: 10 * 60 * 50)

        expectNoPlanInCommittedAudio(records)
        expectUnderrunsExplained(records, initialLead: initialLead, band: band)
        expectContiguityOnlyAtResyncs(records)
        #expect(stats.underruns == 1, "underruns \(stats.underruns) at \(underrunIndices(records).prefix(10))")
        #expect(stats.extraLeadMicros == 60_000, "lead \(stats.extraLeadMicros) µs")
    }

    /// (e) One stall: buffer 500 arrives 200 ms late and the buffers behind it bunch up. The first buffer
    /// counts as the one underrun, and it raises the lead once. Lateness 200 ms is far past reach, so the
    /// stalled buffers are wholly late and dropped. The render phase at the stall is 3.67 ms, so buffers
    /// 500–507 are wholly late (trim ≥ 20 ms), and buffer 508 survives with 1.33 ms (64 frames) trimmed.
    @Test func oneStallIsOneUnderrunAndOneLeadStep() {
        var sim = PlayoutSimulation()
        sim.stalls = [500: 200_000]
        let (records, stats) = sim.run(buffers: 700)

        expectNoPlanInCommittedAudio(records)
        expectUnderrunsExplained(records, initialLead: initialLead, band: band)
        #expect(stats.resyncs == 1)
        #expect(stats.underruns == 1)
        #expect(stats.discontinuities == 0)
        #expect(stats.extraLeadMicros == 60_000)
        #expect(stats.droppedBuffers == 8, "dropped \(stats.droppedBuffers), expected buffers 500…507")
        #expect(planAt(records, index: 500) == nil)

        guard let survivor = records.first(where: { $0.index > 500 && $0.plan != nil }),
              let plan = survivor.plan else {
            Issue.record("no buffer survived the stall")
            return
        }
        #expect(survivor.index == 508)
        #expect(plan.edit == .resync(trimFrames: 64), "survivor edit \(plan.edit)")
        #expect(contiguityBreaks(records) == [508], "contiguity breaks \(contiguityBreaks(records))")
    }

    /// (f) Long stall, with two variants: 500 ms (the first survivor lands exactly on its target, trim 0)
    /// and 520 ms (the survivor is trimmed 64 frames). Either way the whole recovery counts as one resync
    /// and one underrun, and the wholly-late buffers are dropped. The survivor's trimmed PTS maps back onto
    /// the render position within one frame, with the lead included.
    @Test(arguments: [Int64(500_000), 520_000])
    func longStallCountsOneRecoveryAndTrimsTheFirstSurvivor(stallMicros: Int64) {
        var sim = PlayoutSimulation()
        sim.stalls = [500: stallMicros]
        let (records, stats) = sim.run(buffers: 800)

        expectNoPlanInCommittedAudio(records)
        expectUnderrunsExplained(records, initialLead: initialLead, band: band)
        #expect(stats.resyncs == 1)
        #expect(stats.underruns == 1)
        #expect(stats.extraLeadMicros == 60_000)
        let expectedDrops = stallMicros == 500_000 ? 23 : 24
        #expect(stats.droppedBuffers == expectedDrops, "dropped \(stats.droppedBuffers) for stall \(stallMicros)")

        guard let survivor = records.first(where: { $0.index > 500 && $0.plan != nil }),
              let plan = survivor.plan else {
            Issue.record("no buffer survived the stall")
            return
        }
        guard case .resync(let trimFrames) = plan.edit else {
            Issue.record("the first survivor must re-anchor, got \(plan.edit)")
            return
        }
        let expectedTrim = stallMicros == 500_000 ? 0 : 64
        #expect(trimFrames == expectedTrim, "trim \(trimFrames) for stall \(stallMicros)")

        // The trimmed PTS, mapped through the render position the scheduler used and the lead in force,
        // must land on the start sample to within one frame.
        let trimmedPTS = survivor.pts + UInt64((Double(trimFrames) * 1_000_000 / 48_000).rounded())
        let clockTarget = PlayoutSimulation.clock().targetPresentTimeMicros(forPTSMicros: trimmedPTS)
        let delta = Double(clockTarget - survivor.render.hostMicros) + Double(survivor.extraLeadMicros)
        let mapped = survivor.render.sampleTime + Int64((delta * 48_000 / 1_000_000).rounded())
        #expect(abs(mapped - plan.startSample) <= 1, "start \(plan.startSample) maps to \(mapped)")
    }

    /// (g) A source discontinuity: PTS skips 8 buffers (160 ms) with no arrival stall. It is a
    /// discontinuity, not an underrun, so the lead is left alone. The re-anchor leaves a 7,680-frame gap.
    @Test func ptsDiscontinuityIsADiscontinuityNotAnUnderrunAndLeavesTheLead() {
        var sim = PlayoutSimulation()
        sim.ptsSkips = [500: 8]
        let (records, stats) = sim.run(buffers: 600)

        expectNoPlanInCommittedAudio(records)
        #expect(stats.discontinuities == 1)
        #expect(stats.underruns == 0)
        #expect(stats.extraLeadMicros == initialLead)
        guard let before = planAt(records, index: 499), let after = planAt(records, index: 500) else {
            Issue.record("buffers around the discontinuity were not both planned")
            return
        }
        let gap = after.startSample - (before.startSample + Int64(before.outputFrames))
        #expect(abs(gap - 7_680) <= 2, "gap \(gap) frames, expected about 7,680")
    }

    /// (h) No render position yet: the buffer drops, and the next buffer anchors without counting a
    /// recovery.
    @Test func missingRenderPositionDropsThenTheNextBufferAnchorsWithoutAResync() {
        var scheduler = AudioPlayoutScheduler(configuration: .init(sampleRate: 48_000))
        let dropped = scheduler.plan(ptsMicros: 1_000_000, frames: 960,
                                     targetMicros: 1_050_000, render: nil)
        #expect(dropped == nil)
        #expect(scheduler.stats.droppedBuffers == 1)

        let render = AudioRenderPosition(hostMicros: 1_000_000, sampleTime: 48_000)
        let anchored = scheduler.plan(ptsMicros: 1_000_000, frames: 960,
                                      targetMicros: 1_050_000, render: render)
        #expect(anchored?.edit == .resync(trimFrames: 0))
        #expect(scheduler.stats.resyncs == 0)
        #expect(scheduler.stats.droppedBuffers == 1)
    }

    /// (i) Hostile targets and render extremes must not trap. Every Int64 extreme reaches the saturating
    /// arithmetic, the clamps, and the frame conversions.
    @Test(arguments: [Int64.max, Int64.min, 0, 1_000_000])
    func hostileTargetsAndRenderExtremesNeverTrap(targetMicros: Int64) {
        let extremes = [
            AudioRenderPosition(hostMicros: .min, sampleTime: .min),
            AudioRenderPosition(hostMicros: .max, sampleTime: .max),
            AudioRenderPosition(hostMicros: .max, sampleTime: .min),
            AudioRenderPosition(hostMicros: .min, sampleTime: .max),
            AudioRenderPosition(hostMicros: 0, sampleTime: 0),
        ]
        var scheduler = AudioPlayoutScheduler(configuration: .init(sampleRate: 48_000))
        for render in extremes {
            _ = scheduler.plan(ptsMicros: .max, frames: 960, targetMicros: targetMicros, render: render)
            _ = scheduler.plan(ptsMicros: 0, frames: 960, targetMicros: targetMicros, render: render)
            _ = scheduler.plan(ptsMicros: .max, frames: 1, targetMicros: targetMicros, render: render)
            _ = scheduler.plan(ptsMicros: 1, frames: 1 << 20, targetMicros: targetMicros, render: render)
        }
        #expect(scheduler.stats.scheduledBuffers + scheduler.stats.droppedBuffers > 0)
    }

    /// A malformed frame count must not trap when a repeat splice would grow it past `Int.max`. The repeat
    /// is left out, and a buffer of `Int.max` frames has no representable end, so it drops rather than plan.
    @Test func absurdFrameCountCannotOverflowARepeatSplice() {
        var scheduler = AudioPlayoutScheduler(configuration: .init(sampleRate: 48_000))
        let render = AudioRenderPosition(hostMicros: 0, sampleTime: 0)
        _ = scheduler.plan(ptsMicros: 0, frames: 960, targetMicros: 50_000, render: render)
        // Running about 30 ms early against the clock would call for a 240-frame repeat here.
        let plan = scheduler.plan(ptsMicros: 20_000, frames: .max, targetMicros: 100_000, render: render)
        #expect(plan == nil)
        #expect(scheduler.stats.splices == 0)
    }

    /// (j) reset(): the next buffer re-anchors. The anchor is not counted as a resync, and the other
    /// counters are preserved and keep counting.
    @Test func resetRestartsTheAnchorAndKeepsStats() {
        var scheduler = AudioPlayoutScheduler(configuration: .init(sampleRate: 48_000))
        for index in 0..<100 {
            _ = feedCleanBuffer(&scheduler, index: index)
        }
        let before = scheduler.stats
        #expect(before.scheduledBuffers == 100)

        scheduler.reset()
        let anchored = feedCleanBuffer(&scheduler, index: 100)
        #expect(anchored?.edit == .resync(trimFrames: 0))

        let after = scheduler.stats
        #expect(after.resyncs == before.resyncs)
        #expect(after.underruns == before.underruns)
        #expect(after.discontinuities == before.discontinuities)
        #expect(after.splices == before.splices)
        #expect(after.droppedBuffers == before.droppedBuffers)
        #expect(after.scheduledBuffers == before.scheduledBuffers + 1)
    }

    /// (k) Six underruns, each from a 300 ms stall that is past any lead the scheduler can reach. Each
    /// underrun steps the lead by exactly 20 ms, 40 → 60 → 80 → 100 → 120, and the ceiling holds after
    /// that. Each stall drops several wholly-late buffers, and still counts as exactly one underrun.
    @Test func eachUnderrunRaisesTheLeadOnceAndTheCeilingHolds() {
        var sim = PlayoutSimulation()
        sim.stalls = [500: 300_000, 1_000: 300_000, 1_500: 300_000, 2_000: 300_000, 2_500: 300_000, 3_000: 300_000]
        let (records, stats) = sim.run(buffers: 3_600)

        expectNoPlanInCommittedAudio(records)
        expectUnderrunsExplained(records, initialLead: initialLead, band: band)
        let underruns = underrunIndices(records)
        #expect(underruns.count == 6, "underruns \(underruns)")
        let leads = underruns.map { records[$0].extraLeadMicros }
        #expect(leads == [60_000, 80_000, 100_000, 120_000, 120_000, 120_000], "leads at underruns \(leads)")
        #expect(stats.extraLeadMicros == 120_000)
        #expect(stats.droppedBuffers > stats.underruns, "wholly-late runs should drop several buffers each")
    }

    /// (l) The learned lead survives reset(); only a new scheduler starts at the initial value. An underrun
    /// raises it to 60 ms, and after reset the next anchor uses 60 ms: S + fr(50 + 60 ms) = S + 5,280.
    @Test func learnedLeadSurvivesResetAndSeedsTheNextAnchor() {
        var scheduler = AudioPlayoutScheduler(configuration: .init(sampleRate: 48_000))
        #expect(scheduler.stats.extraLeadMicros == 40_000)
        for index in 0..<50 {
            _ = feedCleanBuffer(&scheduler, index: index)
        }
        // The render position jumps 10,000 frames ahead, so the next grid slot is already committed.
        let jumpArrival: Int64 = 1_000_000 + 20_000 * 50
        let jumped = AudioRenderPosition(hostMicros: jumpArrival, sampleTime: jumpArrival * 48 / 1_000 + 10_000)
        _ = scheduler.plan(ptsMicros: UInt64(jumpArrival), frames: 960,
                           targetMicros: jumpArrival + 50_000, render: jumped)
        #expect(scheduler.stats.underruns == 1)
        #expect(scheduler.stats.extraLeadMicros == 60_000)

        scheduler.reset()
        #expect(scheduler.stats.extraLeadMicros == 60_000)
        let anchored = feedCleanBuffer(&scheduler, index: 51)
        let arrival51: Int64 = 1_000_000 + 20_000 * 51
        #expect(anchored?.edit == .resync(trimFrames: 0))
        #expect(anchored?.startSample == arrival51 * 48 / 1_000 + 5_280)
        #expect(scheduler.stats.resyncs == 1, "the anchor after reset is not a recovery")
    }

    /// (m) The committed floor is enforced even when minLead is configured to zero: a plan never starts
    /// inside the render cycle the player has already committed.
    @Test func committedFloorHoldsEvenWithoutMinLead() {
        var configuration = AudioPlayoutScheduler.Configuration(sampleRate: 48_000)
        configuration.minLeadMicros = 0
        configuration.initialExtraLeadMicros = 0
        var scheduler = AudioPlayoutScheduler(configuration: configuration)
        let render = AudioRenderPosition(hostMicros: 1_000_000, sampleTime: 48_000)
        // The clock wants this buffer now. Without the floor it would start inside committed audio.
        #expect(scheduler.plan(ptsMicros: 1_000_000, frames: 960,
                               targetMicros: 1_000_000, render: render) == nil)
        let plan = scheduler.plan(ptsMicros: 1_000_000, frames: 2_048,
                                  targetMicros: 1_000_000, render: render)
        guard let plan else {
            Issue.record("a 2048-frame buffer must survive the committed floor")
            return
        }
        // S + 1025 = 48,000 + 1,025: the committed cycle plus the one-sample reporting tolerance.
        #expect(plan.startSample == 49_025)
    }

    /// The reported sample can sit one frame low. The floor still clears the true committed boundary, so
    /// a start is never inside audio the player rendered, whichever way the report is off.
    @Test func committedFloorToleratesOneSampleOfReportingError() {
        var configuration = AudioPlayoutScheduler.Configuration(sampleRate: 48_000)
        configuration.minLeadMicros = 0
        configuration.initialExtraLeadMicros = 0
        var scheduler = AudioPlayoutScheduler(configuration: configuration)
        // The true sample is 48,000, so the true committed boundary is 49,024. The report says 47,999.
        let render = AudioRenderPosition(hostMicros: 1_000_000, sampleTime: 47_999)
        let plan = scheduler.plan(ptsMicros: 1_000_000, frames: 2_048,
                                  targetMicros: 1_000_000, render: render)
        guard let plan else {
            Issue.record("a 2048-frame buffer must survive the committed floor")
            return
        }
        #expect(plan.startSample >= 49_024, "start \(plan.startSample) is inside committed audio")
    }

    /// A render position so close to Int64.max that its committed boundary is unrepresentable has no legal
    /// start. The buffer drops rather than planning a saturated start.
    @Test func renderPositionNearInt64MaxDropsInsteadOfPlanningASaturatedStart() {
        var scheduler = AudioPlayoutScheduler(configuration: .init(sampleRate: 48_000))
        let render = AudioRenderPosition(hostMicros: 0, sampleTime: .max - 100)
        #expect(scheduler.plan(ptsMicros: 0, frames: 960, targetMicros: 0, render: render) == nil)
        #expect(scheduler.stats.droppedBuffers == 1)
        #expect(scheduler.stats.scheduledBuffers == 0)
    }

    /// A buffer whose start is representable but whose end is not must drop, not plan. Otherwise its
    /// saturated end would make the next buffer start over it, so buffer intervals would overlap. The
    /// first buffer starts at `max − 1,000` (S + the 40 ms lead) and would end past Int64.max. It drops,
    /// and the next buffer anchors at its own start with a representable end.
    @Test func bufferWhoseEndIsUnrepresentableDropsAndNeverOverlaps() {
        var scheduler = AudioPlayoutScheduler(configuration: .init(sampleRate: 48_000))
        let render = AudioRenderPosition(hostMicros: 0, sampleTime: .max - 2_920)
        #expect(scheduler.plan(ptsMicros: 0, frames: 2_000, targetMicros: 0, render: render) == nil)
        let next = scheduler.plan(ptsMicros: 41_667, frames: 960, targetMicros: 0, render: render)
        #expect(next?.startSample == Int64.max - 1_000)
        #expect(next?.edit == .resync(trimFrames: 0))
        #expect(scheduler.stats.scheduledBuffers == 1)
        #expect(scheduler.stats.droppedBuffers == 1)
        #expect(scheduler.stats.splices == 0)
    }

    /// (n) Sustained +100 ms from buffer 600: the delay rises and stays, with small jitter (0–10 ms). The first
    /// underrun raises the lead to 60 ms, and the re-anchor is then wholly late. The late run is judged across
    /// drops, and it tries to escalate, but the escalation does not fit. The lead needed is 60 + trim + 10 + one
    /// render cycle, which is about 156 ms minus the phase. The phase is under 21.3 ms, so the need is above 134 ms,
    /// beyond the 120 ms ceiling for every phase. The run therefore requests exactly one clock re-anchor and no
    /// escalation. After the rebuilt clock sees no lateness, audio is clean: no drops and no underruns for five
    /// minutes.
    @Test func sustainedHundredMillisecondStepRequestsOneReanchorAndThenPlaysClean() {
        var sim = PlayoutSimulation()
        sim.driftPPM = 10.9
        sim.jitter = .uniform(maxMicros: 10_000)
        sim.sustainedDelayFrom = 600
        sim.sustainedDelayMicros = 100_000
        sim.seed = 0x51E9_0100
        let (records, stats) = sim.run(buffers: 600 + 15_500)

        expectNoPlanInCommittedAudio(records)
        expectUnderrunsExplained(records, initialLead: initialLead, band: band)
        expectContiguityOnlyAtResyncs(records)
        #expect(stats.leadEscalations == 0, "escalations \(stats.leadEscalations)")
        #expect(stats.clockReanchors == 1, "clock re-anchors \(stats.clockReanchors)")
        #expect(stats.extraLeadMicros == 120_000, "lead \(stats.extraLeadMicros) µs")

        guard let request = records.first(where: { $0.clockReanchorRequested })?.index,
              let resume = records.first(where: { $0.index > request && $0.plan != nil })?.index else {
            Issue.record("no re-anchor request, or audio never resumed")
            return
        }
        #expect(resume - 600 <= 6, "dropped \(resume - 600) buffers before audio resumed")
        let after = records.dropFirst(resume + 1).prefix(5 * 60 * 50)
        let silentAfterResume = after.filter { $0.plan == nil }.count
        let underrunsAfterResume = after.filter { records[$0.index - 1].underrunsSoFar < $0.underrunsSoFar }.count
        #expect(silentAfterResume == 0, "\(silentAfterResume) drops in the 5 minutes after resumption")
        #expect(underrunsAfterResume == 0, "\(underrunsAfterResume) underruns in the 5 minutes after resumption")
    }

    /// (o) Sustained +300 ms from buffer 600, beyond the ceiling's reach. The late run cannot escalate within
    /// the ceiling, so the lead goes to the ceiling and the caller is asked to re-anchor its clock. The harness
    /// rebuilds the clock from the next buffer, and audio resumes. The rebuilt clock sees no lateness, so no
    /// further re-anchor follows.
    @Test func sustainedThreeHundredMillisecondStepRequestsAClockReanchorAndResumes() {
        var sim = PlayoutSimulation()
        sim.driftPPM = 10.9
        sim.jitter = .uniform(maxMicros: 5_000)
        sim.sustainedDelayFrom = 600
        sim.sustainedDelayMicros = 300_000
        sim.seed = 0x51E9_0300
        let (records, stats) = sim.run(buffers: 600 + 15_500)

        expectNoPlanInCommittedAudio(records)
        expectUnderrunsExplained(records, initialLead: initialLead, band: band)
        expectContiguityOnlyAtResyncs(records)
        #expect(stats.clockReanchors == 1, "clock re-anchors \(stats.clockReanchors)")
        #expect(stats.leadEscalations == 0, "escalations \(stats.leadEscalations)")
        #expect(stats.extraLeadMicros == 120_000, "lead \(stats.extraLeadMicros) µs")

        guard let request = records.first(where: { $0.clockReanchorRequested })?.index,
              let resume = records.first(where: { $0.index > request && $0.plan != nil })?.index else {
            Issue.record("no re-anchor request, or audio never resumed")
            return
        }
        #expect(resume - 600 <= 6, "dropped \(resume - 600) buffers before audio resumed")
        let silentAfterResume = records.dropFirst(resume + 1).prefix(5 * 60 * 50).filter { $0.plan == nil }.count
        #expect(silentAfterResume == 0, "\(silentAfterResume) drops in the 5 minutes after resumption")
    }

    /// (p) Slow clock drift: arrivals drift 30 ppm later relative to PTS for three hours. Lateness rises slowly
    /// and the lead climbs to its ceiling. Once the lead is at the ceiling, the ceiling underrun rate rule re-anchors
    /// the clock, which resets the lateness to zero. That happens within each epoch, before lateness reaches the drop
    /// threshold, so late-run escalation does not normally fire. Silence stays bounded, and clock re-anchors happen once
    /// the lead saturates. Asserted:
    /// the longest drop run is at most 3, at least one re-anchor, audio at the end, a total drop bound, and an
    /// underrun bound. Both bounds are derived in the body. Jitter is small (0–10 ms), so the bounds measure drift
    /// handling rather than the field tail.
    @Test func slowClockDriftKeepsSilenceBoundedAndRequestsReanchors() {
        var sim = PlayoutSimulation()
        sim.arrivalDriftPPM = 30
        sim.jitter = .uniform(maxMicros: 10_000)
        sim.seed = 0x5_0D21_F700
        let buffers = 3 * 60 * 60 * 50
        let (records, stats) = sim.run(buffers: buffers)

        expectNoPlanInCommittedAudio(records)
        expectUnderrunsExplained(records, initialLead: initialLead, band: band)

        var longestSilence = 0
        var run = 0
        var dropTotal = 0
        for record in records {
            run = record.plan == nil ? run + 1 : 0
            if record.plan == nil { dropTotal += 1 }
            longestSilence = max(longestSilence, run)
        }
        #expect(longestSilence <= 3, "longest run of dropped buffers \(longestSilence)")
        #expect(stats.clockReanchors >= 1, "clock re-anchors \(stats.clockReanchors)")
        #expect(records.last?.plan != nil, "audio still silent at the end")

        // Drop bound. A late run drops at most `sustainedLateBuffers + 2` buffers before it escalates or requests a
        // re-anchor. The first two drops set the trend, and four judgements follow. Each escalation or re-anchor
        // ends its run. Slow drift makes no bursts, so no run is longer. Hence drops ≤ 6 × (re-anchors + escalations).
        #expect(dropTotal <= 6 * (stats.clockReanchors + stats.leadEscalations),
                "dropped \(dropTotal), bound \(6 * (stats.clockReanchors + stats.leadEscalations))")

        // Underrun bound, per clock epoch: at most 16. The count has three parts.
        // (1) Epoch 1 only: the three steps below the ceiling (40 → 60, 60 → 80, 80 → 100 ms) are underruns, but the
        //     rate rule does not record them. The lead stays at the ceiling after a re-anchor, so no later epoch has
        //     any.
        // (2) The rule fires at the tenth recorded ceiling underrun inside 60 s of input audio, so ten per epoch.
        // (3) Slack of three for onset underruns that arrive more slowly than ten a minute, before ten fall in one
        //     window. Each recorded underrun re-anchors the grid, which is why the onset is sparse. Measured with the
        //     threshold at ten: epochs of 14, 10, 10, inside 16. (At six they were 10, 6, 6, 0 against a bound of 12.)
        // The slack is an allowance, not a proof. A violation would mean the onset is sparser than the allowance.
        // Checking each epoch separately stops one epoch from compensating for another.
        var epochUnderruns = 0
        var epochs: [Int] = []
        for (index, record) in records.enumerated() {
            if index > 0 && record.underrunsSoFar > records[index - 1].underrunsSoFar {
                epochUnderruns += 1
            }
            if record.clockReanchorRequested {
                epochs.append(epochUnderruns)
                epochUnderruns = 0
            }
        }
        epochs.append(epochUnderruns)
        #expect(epochs.allSatisfy { $0 <= 16 }, "underruns per clock epoch \(epochs), bound 16 each")
    }

    /// (t) Field case at the ceiling, three seeds, ten minutes each, with the field generator. Asserted: at most one
    /// re-anchor per seed in ten minutes. Max-bunching makes one late arrival produce two to four ceiling underruns
    /// close together, so a threshold of six per 60 s re-anchored spuriously in two of three seeds. The default of
    /// ten gave zero in all three, which is why it is the default. A re-anchor that does happen costs one gap, like
    /// an underrun, so the assertion allows one.
    @Test(arguments: [UInt64(0xF1E1_D000), 0xF1E1_D001, 0xF1E1_D002])
    func fieldCaseAtTheCeilingRarelyReanchors(seed: UInt64) {
        var sim = PlayoutSimulation()
        sim.driftPPM = 10.9
        sim.jitter = .field
        sim.seed = seed
        let (records, stats) = sim.run(buffers: 10 * 60 * 50)

        expectNoPlanInCommittedAudio(records)
        expectUnderrunsExplained(records, initialLead: initialLead, band: band)
        #expect(stats.clockReanchors <= 1, "clock re-anchors \(stats.clockReanchors) for seed \(seed)")
    }

    /// (u) The window forgets. Underruns at the ceiling must fall within `ceilingUnderrunWindowMicros` of input
    /// audio to count together. Five events 20 s apart cannot reach six in any case, so on their own they show
    /// little. Six events 20 s apart are the real test: without eviction the ring would reach six and fire on the
    /// sixth, but with eviction a 60-second window never holds more than four. Six events 10 s apart do request a
    /// re-anchor, on the sixth. The stream has the lead at its ceiling from the start, with an underrun event at each
    /// listed buffer.
    @Test func ceilingUnderrunsForgetOutsideTheWindow() {
        let spacedTwentySeconds = ceilingUnderrunEvents(at: [1_000, 2_000, 3_000, 4_000, 5_000], total: 5_100)
        #expect(spacedTwentySeconds.requests.isEmpty, "five underruns 20 s apart requested \(spacedTwentySeconds.requests)")
        #expect(spacedTwentySeconds.stats.underruns == 5)

        let sixTwentySeconds = ceilingUnderrunEvents(at: [1_000, 2_000, 3_000, 4_000, 5_000, 6_000], total: 6_100)
        #expect(sixTwentySeconds.requests.isEmpty, "six underruns 20 s apart requested \(sixTwentySeconds.requests)")
        #expect(sixTwentySeconds.stats.underruns == 6)

        let tenSeconds = ceilingUnderrunEvents(at: [1_000, 1_500, 2_000, 2_500, 3_000, 3_500], total: 4_000)
        #expect(tenSeconds.requests == [3_500], "six underruns 10 s apart requested \(tenSeconds.requests)")
        #expect(tenSeconds.stats.clockReanchors == 1)
    }

    /// (q) Transient stalls of 500 ms and 1,500 ms are backlog bursts: their trims shrink a buffer per drop, so the
    /// late run never escalates or re-anchors. The lead rises exactly one step, for one underrun.
    @Test(arguments: [Int64(500_000), 1_500_000])
    func transientStallsRaiseTheLeadOnceAndNeverEscalate(stallMicros: Int64) {
        var sim = PlayoutSimulation()
        sim.stalls = [500: stallMicros]
        let (records, stats) = sim.run(buffers: 3_000)

        expectNoPlanInCommittedAudio(records)
        expectUnderrunsExplained(records, initialLead: initialLead, band: band)
        #expect(stats.leadEscalations == 0, "escalations \(stats.leadEscalations) for a \(stallMicros) µs stall")
        #expect(stats.clockReanchors == 0, "re-anchors \(stats.clockReanchors) for a \(stallMicros) µs stall")
        #expect(stats.underruns == 1, "underruns \(stats.underruns) for a \(stallMicros) µs stall")
        #expect(stats.extraLeadMicros == 60_000, "lead \(stats.extraLeadMicros) µs")
    }

    /// (r) The re-anchor request is one-shot. Sustained lateness raises it: a late run past the ceiling here, or
    /// enough underruns at the ceiling within a window in general. With constant
    /// lateness and no render-phase effects, the trims are equal from drop to drop, so the late run escalates on
    /// the sixth drop: the first two drops set the trend, and four judgements follow.
    @Test func clockReanchorRequestIsOneShot() {
        var scheduler = AudioPlayoutScheduler(configuration: .init(sampleRate: 48_000))
        var escalatedAt: Int?
        for index in 0..<8 {
            _ = feedConstantLateBuffer(&scheduler, index: index)
            if scheduler.stats.clockReanchors == 1, escalatedAt == nil {
                escalatedAt = index + 1
            }
        }
        #expect(escalatedAt == 6, "re-anchor requested on drop \(String(describing: escalatedAt))")
        #expect(scheduler.stats.extraLeadMicros == 120_000)
        let firstTake = scheduler.takeClockReanchorRequest()
        let secondTake = scheduler.takeClockReanchorRequest()
        #expect(firstTake, "the request must be visible once")
        #expect(!secondTake, "the request must be taken only once")
    }

    /// A degenerate configuration (zero judgements, zero margin, zero lead, a sample rate where the trim rounds to
    /// no microseconds) must still terminate. The escalation re-plans at most once per judged run, and the cleared
    /// trend stops it from looping.
    @Test func degenerateEscalationConfigurationTerminates() {
        var configuration = AudioPlayoutScheduler.Configuration(sampleRate: 2_048_000)
        configuration.minLeadMicros = 0
        configuration.initialExtraLeadMicros = 0
        configuration.escalationMarginMicros = 0
        configuration.sustainedLateBuffers = 0
        var scheduler = AudioPlayoutScheduler(configuration: configuration)
        let render = AudioRenderPosition(hostMicros: 0, sampleTime: 0)
        for index in 0..<8 {
            _ = scheduler.plan(ptsMicros: UInt64(index), frames: 1, targetMicros: 500, render: render)
        }
        // Reaching this line is the termination check. The render-cycle term gives the escalation a positive
        // increment even when the trim rounds to zero, so the first judged run escalates and its buffer is re-planned.
        #expect(scheduler.stats.droppedBuffers + scheduler.stats.scheduledBuffers == 8)
        #expect(scheduler.stats.leadEscalations == 1)
        #expect(scheduler.stats.clockReanchors == 0)
    }

    /// (s) reset() clears the late-run trend. A run interrupted by reset() needs a full set of judgements again, so
    /// the escalation lands on the sixth drop after the reset, not the third.
    @Test func resetClearsTheLateRunTrend() {
        var scheduler = AudioPlayoutScheduler(configuration: .init(sampleRate: 48_000))
        for index in 0..<3 {
            _ = feedConstantLateBuffer(&scheduler, index: index)
        }
        #expect(scheduler.stats.clockReanchors == 0)
        scheduler.reset()
        var escalatedAt: Int?
        for index in 3..<12 {
            _ = feedConstantLateBuffer(&scheduler, index: index)
            if scheduler.stats.clockReanchors == 1, escalatedAt == nil {
                escalatedAt = index - 2
            }
        }
        #expect(escalatedAt == 6, "re-anchor requested on post-reset drop \(String(describing: escalatedAt))")
    }

    /// (v) A re-anchor never overlaps audio already queued in the player. The schedule runs 7 ms late (inside the
    /// band, so no splice), then the source skips 2 ms of PTS. Anchoring at the ideal start would land 5 ms inside
    /// the previous buffer, which the player still holds. The discontinuity resync must start at or after the queued
    /// end and trim the late head instead.
    @Test func resyncAfterASmallPTSGapNeverOverlapsQueuedAudio() throws {
        var scheduler = AudioPlayoutScheduler(configuration: .init(sampleRate: 48_000))
        var previous: AudioPlayoutPlan?
        for index in 0..<20 {
            previous = feedShiftedBuffer(&scheduler, index: index, targetShift: index < 10 ? 0 : -7_000) ?? previous
        }
        let last = try #require(previous)
        let queuedEnd = last.startSample + Int64(last.outputFrames)
        let gapped = feedShiftedBuffer(&scheduler, index: 20, ptsGap: 2_000, targetShift: -7_000)
        #expect(scheduler.stats.discontinuities == 1)
        let plan = try #require(gapped)
        #expect(plan.startSample >= queuedEnd, "resync at \(plan.startSample) overlaps queued audio ending \(queuedEnd)")
    }

    /// (w) A large late error resyncs at the queued end. The first ten buffers are scheduled 120 ms later than the
    /// clock later wants (as when a re-anchor lowers the latency while the player still holds audio for the old
    /// mapping), so the queue runs 120 ms ahead: past the 100 ms resync threshold, yet every target is still ahead
    /// of the committed floor. The scheduler must not start inside the queued audio. It drops the wholly-late
    /// buffers as a shrinking backlog (no escalation, no clock re-anchor), then resumes exactly at the queued end.
    @Test func largeLateErrorCatchesUpAfterQueuedAudioWithoutOverlap() throws {
        var scheduler = AudioPlayoutScheduler(configuration: .init(sampleRate: 48_000))
        var queuedEnd = Int64.min
        var overlaps: [Int] = []
        var firstPlanAfterShift: AudioPlayoutPlan?
        var queuedEndAtShift = Int64.min
        for index in 0..<40 {
            if index == 10 { queuedEndAtShift = queuedEnd }
            guard let plan = feedShiftedBuffer(&scheduler, index: index, targetShift: index < 10 ? 120_000 : 0)
            else { continue }
            if plan.startSample < queuedEnd { overlaps.append(index) }
            if index >= 10, firstPlanAfterShift == nil { firstPlanAfterShift = plan }
            queuedEnd = plan.startSample + Int64(plan.outputFrames)
        }
        #expect(overlaps.isEmpty, "plans overlapping queued audio at \(overlaps)")
        #expect(scheduler.stats.leadEscalations == 0)
        #expect(scheduler.stats.clockReanchors == 0)
        #expect(scheduler.stats.droppedBuffers > 0, "the late head should be dropped while catching up")
        let catchUp = try #require(firstPlanAfterShift)
        #expect(catchUp.startSample == queuedEndAtShift, "catch-up should resume exactly at the queued end")
        // It resumes right after queued audio, so it must say so: the integrator then joins it continuously
        // instead of fading in from silence.
        if case .resync = catchUp.edit {} else { Issue.record("catch-up should be a resync, got \(catchUp.edit)") }
        #expect(catchUp.followsQueuedAudio)
    }

    /// (x) `followsQueuedAudio` is true exactly when a plan starts where the previous one ended. The first anchor
    /// follows nothing; contiguous plans always follow; an underrun resync starts after a silent gap and does not.
    @Test func followsQueuedAudioMarksOnlyBackToBackPlans() throws {
        var scheduler = AudioPlayoutScheduler(configuration: .init(sampleRate: 48_000))
        let firstPlan = feedCleanBuffer(&scheduler, index: 0)
        let first = try #require(firstPlan)
        #expect(!first.followsQueuedAudio)
        for index in 1..<20 {
            let contiguous = feedCleanBuffer(&scheduler, index: index)
            #expect(try #require(contiguous).followsQueuedAudio)
        }
        // The render position jumps 10,000 frames ahead: the queue ran dry, so the re-anchor leaves a gap.
        let arrival: Int64 = 1_000_000 + 20_000 * 20
        let jumped = AudioRenderPosition(hostMicros: arrival, sampleTime: arrival * 48 / 1_000 + 10_000)
        let recoveryPlan = scheduler.plan(ptsMicros: UInt64(arrival), frames: 960,
                                          targetMicros: arrival + 50_000, render: jumped)
        let recovery = try #require(recoveryPlan)
        #expect(scheduler.stats.underruns == 1)
        #expect(!recovery.followsQueuedAudio)
    }

    /// (y) The committed floor follows the route's render cycle. With no minimum lead and a 4,096-frame cycle
    /// (a large Bluetooth IO buffer), a buffer whose ideal start is 3,360 frames out (70 ms, inside that cycle)
    /// must start past `S + 4,096`, trimming its late head. A fixed 1,024-frame floor would start it at S + 3,360,
    /// in audio the route has already rendered.
    @Test func committedFloorFollowsTheReportedRenderCycle() throws {
        var configuration = AudioPlayoutScheduler.Configuration(sampleRate: 48_000)
        configuration.minLeadMicros = 0
        configuration.initialExtraLeadMicros = 0
        var scheduler = AudioPlayoutScheduler(configuration: configuration)
        let render = AudioRenderPosition(hostMicros: 1_000_000, sampleTime: 48_000, cycleFrames: 4_096)
        let planned = scheduler.plan(ptsMicros: 1_000_000, frames: 960, targetMicros: 1_070_000, render: render)
        let plan = try #require(planned)
        #expect(plan.startSample >= 48_000 + 4_097, "start \(plan.startSample) inside a 4,096-frame cycle")
    }

    /// (aa) A recovery that would keep only one frame (trim 959 of 960) is dropped rather than scheduled with a
    /// fade-in cut to that single, silent frame, which would click into its full-amplitude successor. The next
    /// buffer re-anchors with a whole buffer and a whole fade, and the drop is not counted as a recovery.
    @Test func recoveryTooShortForItsFadeIsDroppedAndTheSuccessorFadesWhole() throws {
        var configuration = AudioPlayoutScheduler.Configuration(sampleRate: 48_000)
        configuration.minLeadMicros = 0
        configuration.initialExtraLeadMicros = 0
        var scheduler = AudioPlayoutScheduler(configuration: configuration)
        // Earliest = S + 1,025. Ideal = S + fr(1,375 µs) = S + 66, so the trim is 959 and one frame would survive.
        let render = AudioRenderPosition(hostMicros: 1_000_000, sampleTime: 48_000)
        let short = scheduler.plan(ptsMicros: 1_000_000, frames: 960, targetMicros: 1_001_375, render: render)
        #expect(short == nil, "a one-frame recovery must not be scheduled: \(String(describing: short))")
        #expect(scheduler.stats.droppedBuffers == 1)
        // The successor's ideal start is S + 1,026, past the floor: it anchors whole, with a full fade.
        let successorPlan = scheduler.plan(ptsMicros: 1_020_000, frames: 960, targetMicros: 1_021_375, render: render)
        let successor = try #require(successorPlan)
        #expect(successor.edit == .resync(trimFrames: 0))
        #expect(successor.outputFrames == 960)
        #expect(scheduler.stats.resyncs == 0, "the drop and re-anchor are one unanchored start, not a recovery")
    }

    /// (ab) A Bluetooth-like route hears a rendered sample 200 ms later. Without route compensation every ideal
    /// start falls behind the committed floor, even at the maximum lead, so nearly everything drops (and a clock
    /// re-anchor recreates the same budget). With the integrator's compensation (`AudioRouteLatency`, here 155 ms
    /// beyond the speaker's 45 ms) the same route plays: the oracle holds and there are no underruns after the lead
    /// settles.
    @Test func highLatencyRoutePlaysOnlyWithRouteCompensation() {
        var silent = PlayoutSimulation()
        silent.outputLatencyMicros = 200_000
        silent.jitter = .uniform(maxMicros: 10_000)
        let (silentRecords, _) = silent.run(buffers: 2 * 60 * 50)
        let silentPlanned = silentRecords.filter { $0.plan != nil }.count
        #expect(silentPlanned * 10 < silentRecords.count, "uncompensated route planned \(silentPlanned) buffers")

        var compensated = silent
        compensated.targetCompensationMicros = AudioRouteLatency.compensationMicros(
            outputLatency: 0.2 - 0.021_333, ioBufferDuration: 0.021_333)
        #expect(compensated.targetCompensationMicros == 155_000)
        let (records, stats) = compensated.run(buffers: 2 * 60 * 50)
        expectNoPlanInCommittedAudio(records)
        let lateUnderruns = underrunIndices(records).filter { $0 >= 50 }
        #expect(lateUnderruns.isEmpty, "underruns after the first second: \(lateUnderruns.prefix(5))")
        #expect(stats.clockReanchors == 0)
    }

    /// (z) The field case on a route that renders 2,048 frames per cycle (42.7 ms): the oracle (no plan in
    /// committed audio, none overlapping queued audio) still holds when the committed boundary is twice as far out.
    @Test func fieldCaseOnALargerRenderCycleKeepsTheOracle() {
        var sim = PlayoutSimulation()
        sim.driftPPM = 10.9
        sim.jitter = .field
        sim.renderCycleFrames = 2_048
        let (records, _) = sim.run(buffers: 10 * 60 * 50)
        expectNoPlanInCommittedAudio(records)
    }
}

/// Clean 20 ms stream with the lead held at its ceiling, and an underrun event at each listed buffer. An event
/// advances the render position by 10,000 frames for that one buffer, so its grid slot is already committed and it
/// underruns. The next buffer then re-anchors on the clean render position. Returns the indices where a clock
/// re-anchor was requested.
private func ceilingUnderrunEvents(at events: Set<Int>, total: Int)
    -> (requests: [Int], stats: AudioPlayoutStats) {
    var configuration = AudioPlayoutScheduler.Configuration(sampleRate: 48_000)
    configuration.initialExtraLeadMicros = 120_000
    // Pinned so the window cases below (six events) test eviction independently of the default threshold.
    configuration.ceilingUnderrunsBeforeReanchor = 6
    var scheduler = AudioPlayoutScheduler(configuration: configuration)
    var requests: [Int] = []
    for index in 0..<total {
        let arrival: Int64 = 1_000_000 + 20_000 * Int64(index)
        let jump: Int64 = events.contains(index) ? 10_000 : 0
        let render = AudioRenderPosition(hostMicros: arrival, sampleTime: arrival * 48 / 1_000 + jump)
        _ = scheduler.plan(ptsMicros: UInt64(arrival), frames: 960, targetMicros: arrival + 50_000, render: render)
        if scheduler.takeClockReanchorRequest() {
            requests.append(index)
        }
    }
    return (requests, scheduler.stats)
}

/// Constant lateness with no render-phase effects: each buffer's target sits 250 ms before its arrival, and its
/// host time is 45 ms after arrival. The trim is the same on every drop, so the run judges steady lateness.
private func feedConstantLateBuffer(_ scheduler: inout AudioPlayoutScheduler, index: Int) -> AudioPlayoutPlan? {
    let arrival: Int64 = 1_000_000 + 20_000 * Int64(index)
    let host = arrival + 45_000
    let render = AudioRenderPosition(hostMicros: host, sampleTime: host * 48 / 1_000)
    return scheduler.plan(ptsMicros: UInt64(arrival), frames: 960,
                          targetMicros: arrival - 250_000, render: render)
}

private func planAt(_ records: [PlayoutSimulation.Record], index: Int) -> AudioPlayoutPlan? {
    records.first { $0.index == index }?.plan
}

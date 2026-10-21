// SPDX-License-Identifier: Apache-2.0
/// Where the audio player is on its own sample timeline, sampled at one instant.
///
/// The player renders in cycles of `cycleFrames` frames, the route's IO buffer (1,024 frames, 21.3 ms at
/// 48 kHz on Roshar's speaker; larger on some routes). `sampleTime` is the sample `S` that starts the last
/// rendered cycle, and `hostMicros` is the moment `S` will be heard. That moment is about 24–45 ms in the
/// future when the position is read, so `hostMicros` is not "now". Samples below `S + cycleFrames` are
/// already committed and can no longer be rewritten.
public struct AudioRenderPosition: Sendable, Equatable {
    /// Local uptime (µs, same timeline as PresentationClock targets) at which `sampleTime` is heard.
    public var hostMicros: Int64
    /// Player-timeline sample that starts the last rendered cycle.
    public var sampleTime: Int64
    /// Frames the player commits per render cycle on the current route, in player-timeline frames. The caller
    /// derives it from the live route (it changes with the output device), so the committed floor tracks it.
    public var cycleFrames: Int64

    public init(hostMicros: Int64, sampleTime: Int64, cycleFrames: Int64 = 1_024) {
        self.hostMicros = hostMicros
        self.sampleTime = sampleTime
        self.cycleFrames = cycleFrames
    }
}

/// How a buffer's frames are altered before it is scheduled. Splices are crossfaded by ``AudioSplice``.
public enum AudioSpliceEdit: Sendable, Equatable {
    case none
    /// Audio is running late vs the clock: drop `frames` samples from the head, crossfaded.
    case skip(frames: Int)
    /// Audio is running early vs the clock: insert `frames` samples by replaying the head, crossfaded.
    case repeatHead(frames: Int)
    /// Start of a new segment (first buffer, underrun, discontinuity, huge error): discard
    /// `trimFrames` leading samples (they are already late), then fade in.
    case resync(trimFrames: Int)
}

/// One scheduled buffer: where it starts on the player timeline and how it is edited.
public struct AudioPlayoutPlan: Sendable, Equatable {
    /// Player-timeline sample where the edited buffer starts.
    public let startSample: Int64
    public let edit: AudioSpliceEdit
    /// Frame count after applying `edit`.
    public let outputFrames: Int
    /// True when this buffer starts exactly where the previously scheduled one ends, so the player plays them
    /// back-to-back. Contiguous plans always do. A `.resync` that does must join the queued audio continuously
    /// (``AudioSplice`` crossfades from the previous buffer's last sample) instead of fading in from silence,
    /// which would step from that last sample straight to zero.
    public let followsQueuedAudio: Bool
}

/// Running counters for diagnostics. Counters only ever grow, except the "last", "queued" and
/// "extra lead" gauges.
public struct AudioPlayoutStats: Sendable, Equatable {
    public var scheduledBuffers = 0
    /// Plans with `.skip` or `.repeatHead`.
    public var splices = 0
    /// Recovery re-anchors (NOT the initial anchor or the anchor after `reset()`).
    public var resyncs = 0
    /// Resyncs because the queue ran dry. Each one also raises the adaptive lead by one step.
    public var underruns = 0
    /// Resyncs because the host PTS jumped.
    public var discontinuities = 0
    /// No render position yet, frames <= 0, or wholly late at a resync.
    public var droppedBuffers = 0
    /// Schedule error vs the clock at the last plan (+ = audio late).
    public var lastErrorMicros: Int64 = 0
    /// Scheduled-but-unplayed audio ahead of the render position.
    public var queuedMicros: Int64 = 0
    /// Adaptive audio lead in force (µs). Audio deliberately lags the A/V clock by this much.
    public var extraLeadMicros: Int64 = 0
    /// Sustained late runs the lead covered by raising itself, without a clock re-anchor.
    public var leadEscalations = 0
    /// Sustained late runs the lead could not cover, so the caller was asked to re-anchor its clock.
    public var clockReanchors = 0

    public init() {}
}

/// Plans where each incoming audio buffer starts on the player's own sample timeline, keeping the
/// schedule within a band of the A/V presentation clock.
///
/// **Why this exists.** Scheduling every buffer at an absolute host time derived from the sender's
/// PTS fails when the two clocks disagree. The iPhone renders 48,000.52 samples/s while PTS advance
/// exactly 20,000 µs per 960 frames, so per-buffer host placements slip about +10.9 ppm. That is a
/// one-sample gap or overlap roughly every 1.9 s, which is audible as clicks. The fix is to place
/// buffers back-to-back on the player's sample timeline and correct the accumulated drift only
/// occasionally, with small crossfaded splices.
///
/// **Committed audio.** A buffer must never start in audio the player has already rendered. The
/// earliest legal start is `S + max(fr(minLead), cycle + 1)`, where `S` is the render position's sample and
/// `cycle` its `cycleFrames` (the route's render cycle, so a larger IO buffer raises the floor with it). The floor
/// is one render cycle plus one sample of reporting tolerance, and it applies whatever `minLead` is configured.
/// If the boundary itself is unrepresentable near `Int64.max`, the buffer is dropped.
///
/// **Adaptive lead (a minimal jitter buffer).** Network arrival jitter can exceed the headroom the
/// clock leaves, and an underrun costs a resync, which is an audible gap. So the scheduler keeps an
/// `extraLead` that delays every ideal start by that amount. Each underrun recovery raises it by
/// `underrunLeadStepMicros`, up to `maxExtraLeadMicros`. It is raised before the re-anchor is
/// computed, so the re-anchor already uses the larger lead. Consequence: audio deliberately lags the
/// A/V clock (and video) by `extraLead`. Audio lagging video by up to about 120 ms is within
/// broadcast lip-sync tolerance, whereas audio leading video is not. Discontinuities and huge-error
/// resyncs are not jitter, so they do not raise the lead. `reset()` keeps the learned lead, since it
/// reflects this session's network. Only a new scheduler starts again at `initialExtraLeadMicros`.
///
/// **Algorithm.** Let `fr(µs)` convert microseconds to frames and `us(frames)` convert frames back,
/// both rounding to nearest. For each buffer:
///
/// 1. Drop it (returning nil) when `frames <= 0` or there is no render position. Neither changes
///    state other than the drop counter.
/// 2. Compute `idealStart = render.sampleTime + fr(clamp(target − render.hostMicros) + extraLead)`,
///    the sample the clock wants this buffer at, and `earliest` as above. The delta is clamped to
///    ±60 s and all sums saturate, so no Int64 input can trap.
/// 3. Re-anchor (resync) when any of these holds:
///    - there is no contiguous `nextSample` yet (first buffer, or first after `reset()`); this is
///      not counted as a recovery;
///    - the PTS jumped by more than 1 ms from the previous buffer's end (`discontinuities`);
///    - `nextSample < earliest`, meaning the queue would run dry (`underruns`, and the lead steps up);
///    - `|nextSample − idealStart| > fr(resyncMicros)` (a huge error).
///    The last three also count in `resyncs`.
/// 4. Otherwise place the buffer contiguously at `nextSample`. Let `err = nextSample − idealStart`,
///    so positive means the audio is late. If not already correcting and `|err| <= fr(bandMicros)`,
///    leave it alone (`.none`). Otherwise start correcting. Once `|err| <= fr(settleMicros)` stop
///    (hysteresis). Until then, splice by `k = min(|err|, fr(maxSpliceMicros), frames − crossfade)`:
///    `err > 0` skips `k` frames (the schedule catches up), `err < 0` repeats `k` frames (it slows
///    down).
///
/// **Resync placement.** A resync starts at `max(idealStart, earliest, queuedEnd)` and trims the leading
/// `trim = start − idealStart` frames, which are already late. `queuedEnd` is the end of the audio already handed
/// to the player: it cannot be withdrawn, so a re-anchor never overlaps it, and catches up by trimming instead.
/// Only `reset()` (the player stopped and flushed) forgets it. If the buffer is wholly late, meaning too
/// little survives the trim to carry a whole crossfade (`frames − trim < crossfadeFrames`), it is dropped and
/// the schedule is left unanchored: a shorter fade-in would end early and click into the next buffer. The next buffer then
/// re-anchors without counting a second recovery, so one stall costs one `resyncs`/`underruns`.
///
/// **Sustained lateness.** A stall that queues a backlog clears itself: its buffers arrive together, and the
/// trim shrinks a buffer per drop. Lateness that stays (a Wi-Fi roam, slow clock drift) would silence audio
/// forever, because the lead cannot rise while every buffer drops. Two mechanisms handle it.
///
/// - *Late runs* (`wholeBufferLate`). Wholly-late drops are judged across pairs: a shrink of 30 ms or more over
///   two drops resets the run, which tells a burst from sustained lateness. After `sustainedLateBuffers`
///   judgements, the run escalates. If `lead + trim + margin + one render cycle` fits under the ceiling, the lead
///   rises to that and the same buffer is re-planned (`leadEscalations`). Otherwise the lead goes to the
///   ceiling and a clock re-anchor is requested.
/// - *Ceiling underruns* (`ceilingUnderrunsBeforeReanchor`, `ceilingUnderrunWindowMicros`). Once the lead is at its
///   ceiling, underrun recoveries are recorded by input PTS. Ten of them within a minute of input audio request a
///   clock re-anchor. A rate rule catches slow drift within seconds of onset. Once lateness passes the budget, the
///   underruns come steadily, so ten arrive within the window. Isolated jitter-tail underruns, about two per minute
///   in the field model and bunched two to four at a time, did not reach ten in any measured window, so they do
///   not re-anchor. Underruns below the ceiling are not recorded.
///
/// Both report through `clockReanchors`. The caller takes the request with ``takeClockReanchorRequest()`` and
/// must discard its presentation clock, so the next frame re-anchors it at `offset = pts − now`. It must not call
/// ``reset()``: the player keeps its queue, and taking the request already unanchors the schedule, so the first
/// buffer on the new clock re-anchors after the queued audio. The lead is kept, since it reflects the network and
/// the clock is what drifted. The scheduler never reads or changes a clock itself.
///
/// After any returned plan, `nextSample = start + outputFrames`, `lastEndPTS` becomes the input end
/// PTS (`pts + frames·1e6/sr`, kept as a Double so rounding never accumulates), and
/// `queuedMicros = us(nextSample − render.sampleTime)`.
///
/// This type reads no clock and does no audio work. Every time is a parameter, and the caller owns
/// the realtime wiring (AVAudioPlayerNode scheduling at player-timeline sample times).
public struct AudioPlayoutScheduler: Sendable {
    public struct Configuration: Sendable, Equatable {
        public var sampleRate: Double
        /// Tolerated `|error|` before splicing starts. Keep it small: drift accumulates inside the band,
        /// and the error can sit at the band edge, which the underrun margin has to absorb.
        public var bandMicros: Int64 = 8_000
        /// Keep splicing until `|error|` is at most this (hysteresis). Must sit below `bandMicros`.
        public var settleMicros: Int64 = 3_000
        /// Largest correction applied to one buffer.
        public var maxSpliceMicros: Int64 = 5_000
        /// `|error|` beyond this re-anchors instead of splicing.
        public var resyncMicros: Int64 = 100_000
        /// Earliest a buffer may start ahead of the render position. One render cycle (21.3 ms) plus
        /// margin. The committed-audio floor (one render cycle plus one sample) applies on top of this.
        public var minLeadMicros: Int64 = 30_000
        /// Crossfade length used by ``AudioSplice`` for every splice and resync fade-in.
        public var crossfadeFrames: Int = 64
        /// Adaptive lead at the start of a new scheduler (µs). Covers typical arrival jitter before the
        /// first underrun raises it.
        public var initialExtraLeadMicros: Int64 = 40_000
        /// How much each underrun recovery raises the adaptive lead (µs).
        public var underrunLeadStepMicros: Int64 = 20_000
        /// Ceiling for the adaptive lead (µs). This bounds how far audio can lag the A/V clock.
        public var maxExtraLeadMicros: Int64 = 120_000
        /// Judgements of a late run needed before it escalates (see `wholeBufferLate`). Escalation lands on the
        /// buffer that completes the last judgement, about `sustainedLateBuffers + 2` drops in (about 120 ms at 4).
        public var sustainedLateBuffers: Int = 4
        /// Headroom added to the lead when a late run escalates, on top of covering the trim (µs). The escalation
        /// also adds one full render cycle, because the render position is held for a cycle and the arrival's
        /// phase within it is unknown.
        public var escalationMarginMicros: Int64 = 10_000
        /// Underrun recoveries at the ceiling that must fall inside `ceilingUnderrunWindowMicros` before the lead is
        /// judged unable to cover the lateness, and a clock re-anchor is requested. Isolated jitter-tail underruns at
        /// the ceiling run about two per minute, but one late arrival bunches two to four of them together, so six a
        /// minute still fired spuriously in the field model (two of three seeds per 10 min). Ten never did, and still
        /// catches slow drift within about 35 s of onset.
        public var ceilingUnderrunsBeforeReanchor: Int = 10
        /// The window, in input audio (PTS µs), that the ceiling underruns must fall inside. The scheduler measures
        /// PTS, not wall time, since it reads no clock.
        public var ceilingUnderrunWindowMicros: Int64 = 60_000_000

        public init(sampleRate: Double) {
            self.sampleRate = sampleRate
        }
    }

    public let configuration: Configuration
    public private(set) var stats: AudioPlayoutStats

    /// Where a contiguous next buffer would start, or nil when unanchored.
    private var nextSample: Int64?
    /// End of the last scheduled buffer on the current player timeline. Audio before it is already queued in the
    /// player and cannot be withdrawn, so no plan may start before it, not even a re-anchor. Only `reset()` (the
    /// player stopped and flushed its queue) clears it.
    private var queuedEnd: Int64?
    /// Input PTS end of the previous input buffer (µs, Double so rounding never accumulates).
    private var lastEndPTS: Double?
    /// True while a splice correction is in progress (hysteresis between band and settle).
    private var correcting = false
    /// Adaptive lead currently in force (µs). Kept across `reset()`, since it reflects the network.
    private var extraLeadMicros: Int64
    /// Trims of the last two consecutive wholly-late drops (frames). Cleared by any returned plan and by reset().
    private var lateRunTrim: Int64?
    private var lateRunTrimBefore: Int64?
    /// Non-shrinking judgements in the current late run.
    private var sustainedLateCount = 0
    /// Set when sustained lateness outran the ceiling. It stays set until the caller takes the request.
    private var clockReanchorPending = false
    /// Input PTS (µs) of the underrun recoveries at the ceiling that are still inside the window. It never holds
    /// more than `ceilingUnderrunsBeforeReanchor` entries, since reaching that count requests a re-anchor.
    private var ceilingUnderrunPTS: [UInt64] = []

    /// A PTS step larger than this (µs) from the previous buffer's end is a source discontinuity.
    private static let discontinuityMicros: Double = 1_000
    /// Bound on the clamped target delta, so the frame conversion can never overflow.
    private static let maxDeltaMicros: Int64 = 60_000_000
    /// Upper bound on a reported render cycle, so a corrupt value cannot push the floor arbitrarily far ahead.
    private static let maxCycleFrames: Int64 = 1 << 16

    /// One render cycle of the current route (`render.cycleFrames`, clamped to 1…65,536). It is the single source
    /// for both the committed-audio floor and the escalation margin, so they cannot diverge.
    private static func cycleFrames(_ render: AudioRenderPosition) -> Int64 {
        min(max(render.cycleFrames, 1), maxCycleFrames)
    }

    /// Committed-audio floor, measured from the reported `sampleTime`: one render cycle plus one sample of
    /// reporting tolerance. The reported sample can sit one frame low, and a start must clear the true
    /// committed boundary even then.
    private static func committedFrames(_ render: AudioRenderPosition) -> Int64 {
        cycleFrames(render) + 1
    }

    public init(configuration: Configuration) {
        precondition(configuration.sampleRate > 0 && configuration.sampleRate.isFinite,
                     "the playout scheduler needs a positive, finite sample rate")
        self.configuration = configuration
        let ceiling = max(configuration.maxExtraLeadMicros, 0)
        self.extraLeadMicros = min(max(configuration.initialExtraLeadMicros, 0), ceiling)
        self.stats = AudioPlayoutStats()
        self.stats.extraLeadMicros = extraLeadMicros
    }

    /// The player was stopped or reconfigured, so its sample timeline restarts: the next buffer
    /// anchors afresh. Stats are kept, and the anchor after a reset is not counted as a resync. The
    /// learned adaptive lead is kept too, because it reflects this session's network jitter.
    public mutating func reset() {
        nextSample = nil
        queuedEnd = nil
        lastEndPTS = nil
        correcting = false
        clearLateRun()
        ceilingUnderrunPTS.removeAll()
    }

    /// Returns true once per clock re-anchor request, then clears it.
    ///
    /// Contract for the caller. When this returns true, discard the presentation clock (and any video mapping
    /// derived from it), so the next frame re-anchors it at `offset = pts − now`, the same rule as the initial
    /// anchor. Do NOT call ``reset()``: the player keeps playing the audio it already queued. Taking the request
    /// unanchors the schedule itself, so the first buffer on the new clock re-anchors after that queued audio,
    /// without counting a resync. The scheduler never reads or changes a clock itself. It requests a re-anchor in
    /// two cases: sustained lateness the lead cannot cover (a late run past the ceiling), and enough underruns at
    /// the ceiling within a window of input audio. The request is one-shot, and it is never taken twice.
    public mutating func takeClockReanchorRequest() -> Bool {
        let pending = clockReanchorPending
        clockReanchorPending = false
        if pending {
            nextSample = nil
            correcting = false
            clearLateRun()
        }
        return pending
    }

    /// Plans one incoming buffer. Returns nil when the buffer must be dropped.
    public mutating func plan(ptsMicros: UInt64, frames: Int, targetMicros: Int64,
                              render: AudioRenderPosition?) -> AudioPlayoutPlan? {
        guard frames > 0, let render else {
            stats.droppedBuffers += 1
            return nil
        }
        let endPTS = Double(ptsMicros) + Double(frames) * 1_000_000 / configuration.sampleRate
        let leadFrames = max(framesFrom(micros: configuration.minLeadMicros), Self.committedFrames(render))
        let (earliestSample, overflow) = render.sampleTime.addingReportingOverflow(leadFrames)
        // The committed boundary itself is unrepresentable near Int64.max, so no legal start exists.
        // Drop the buffer rather than plan a saturated start into committed audio.
        guard !overflow else {
            stats.droppedBuffers += 1
            return nil
        }
        let earliest = earliestSample

        guard let next = nextSample else {
            return resynchronize(endPTS: endPTS, targetMicros: targetMicros, earliest: earliest,
                                 inputFrames: frames, render: render)
        }
        if let lastEnd = lastEndPTS, abs(Double(ptsMicros) - lastEnd) > Self.discontinuityMicros {
            stats.discontinuities += 1
            stats.resyncs += 1
            return resynchronize(endPTS: endPTS, targetMicros: targetMicros, earliest: earliest,
                                 inputFrames: frames, render: render)
        }
        if next < earliest {
            stats.underruns += 1
            stats.resyncs += 1
            // Raise the lead before the re-anchor computes its ideal start, so the re-anchor uses it.
            raiseExtraLead()
            // At the ceiling the lead cannot grow, so an underrun here is lateness the lead cannot cover. Enough of
            // them within the window is sustained lateness, and it requests a clock re-anchor. This buffer still
            // re-anchors as usual.
            if extraLeadMicros >= max(configuration.maxExtraLeadMicros, 0) {
                recordCeilingUnderrun(ptsMicros: ptsMicros)
            }
            return resynchronize(endPTS: endPTS, targetMicros: targetMicros, earliest: earliest,
                                 inputFrames: frames, render: render)
        }
        let ideal = idealStart(targetMicros, render)
        let error = next.saturatingSubtracting(ideal)
        if Self.magnitude(error) > framesFrom(micros: configuration.resyncMicros) {
            stats.resyncs += 1
            return resynchronize(endPTS: endPTS, targetMicros: targetMicros, earliest: earliest,
                                 inputFrames: frames, render: render)
        }
        return contiguous(start: next, error: error, endPTS: endPTS, inputFrames: frames, render: render)
    }

    /// The sample the clock wants a buffer at, including the adaptive lead. All sums saturate, and the
    /// delta is clamped to ±60 s before it is converted, so no input can trap.
    private func idealStart(_ targetMicros: Int64, _ render: AudioRenderPosition) -> Int64 {
        let delta = targetMicros.saturatingSubtracting(render.hostMicros)
        let boundedDelta = min(max(delta, -Self.maxDeltaMicros), Self.maxDeltaMicros)
        let lead = min(max(boundedDelta.saturatingAdding(extraLeadMicros), -Self.maxDeltaMicros),
                       Self.maxDeltaMicros)
        return render.sampleTime.saturatingAdding(framesFrom(micros: lead))
    }

    /// One underrun step: raise the adaptive lead by the configured step, up to the ceiling.
    private mutating func raiseExtraLead() {
        let step = max(configuration.underrunLeadStepMicros, 0)
        let ceiling = max(configuration.maxExtraLeadMicros, 0)
        extraLeadMicros = min(extraLeadMicros.saturatingAdding(step), ceiling)
        stats.extraLeadMicros = extraLeadMicros
    }

    /// Re-anchors at the first still-playable sample, trimming the frames that are already late.
    /// A buffer that is entirely late is dropped, which leaves the schedule unanchored so the next
    /// buffer re-anchors without counting a second recovery.
    private mutating func resynchronize(endPTS: Double, targetMicros: Int64, earliest: Int64,
                                        inputFrames: Int, render: AudioRenderPosition) -> AudioPlayoutPlan? {
        // Computed here, after any lead change, so every re-anchor uses the lead in force.
        let ideal = idealStart(targetMicros, render)
        // Never before audio already queued in the player: a re-anchor that lands inside it (a small PTS gap while
        // the schedule runs late, a large late error, the first buffer on a re-anchored clock) would overlap it.
        // Starting after it and trimming the late head catches up instead.
        let anchor = max(ideal, earliest, queuedEnd ?? earliest)
        let trim = anchor.saturatingSubtracting(ideal)
        // A survivor shorter than one crossfade cannot carry its fade-in: the fade would end early and the next
        // (contiguous, unfaded) buffer would resume at full amplitude, a click. Treat it as wholly late, so the
        // next buffer re-anchors with a whole fade. The bound never exceeds the buffer, so a trim of 0 survives.
        let minimumSurvivor = Int64(min(max(configuration.crossfadeFrames, 1), inputFrames))
        guard Int64(inputFrames).saturatingSubtracting(trim) >= minimumSurvivor else {
            return wholeBufferLate(trim: trim, endPTS: endPTS, targetMicros: targetMicros, earliest: earliest,
                                   inputFrames: inputFrames, render: render)
        }
        correcting = false
        guard let plan = commit(start: anchor, edit: .resync(trimFrames: Int(trim)),
                                outputFrames: inputFrames - Int(trim), endPTS: endPTS, render: render) else {
            return nil
        }
        stats.lastErrorMicros = microsFrom(frames: trim)
        return plan
    }

    /// Handles a wholly-late buffer. A stall that queued a backlog and sustained lateness look alike for one
    /// drop, but differ in trend. A backlog burst (buffers that were queued, all arriving together) shrinks the
    /// trim by about one buffer per drop. Sustained lateness holds the trim roughly steady, except that the
    /// arrival's offset within the 21.3 ms render cycle sawtooths it: one drop can shrink by a whole buffer when
    /// the phase wraps. So the trend is judged across two drops. A burst shrinks by about two buffers in two
    /// drops, and sustained lateness by at most one wrap (20 ms). A shrink of 30 ms or more over two drops resets
    /// the run.
    ///
    /// After `sustainedLateBuffers` non-shrinking judgements, the buffer escalates. If the lead can cover the trim,
    /// the margin, and one render cycle for the worst phase, the lead rises to cover them, and this same buffer is
    /// re-planned. That re-plan fits by construction, and it is not counted as an underrun or resync. Otherwise the
    /// lead goes to the ceiling, a clock re-anchor is requested, and this buffer is dropped.
    private mutating func wholeBufferLate(trim: Int64, endPTS: Double, targetMicros: Int64, earliest: Int64,
                                          inputFrames: Int, render: AudioRenderPosition) -> AudioPlayoutPlan? {
        if let before = lateRunTrimBefore {
            if trim > before - framesFrom(micros: 30_000) {
                sustainedLateCount += 1
            } else {
                sustainedLateCount = 0
            }
        }
        lateRunTrimBefore = lateRunTrim
        lateRunTrim = trim
        // At least one judgement, so an escalation always follows a judged run. The re-plan below then starts from
        // a cleared trend and cannot escalate again.
        guard sustainedLateCount >= max(configuration.sustainedLateBuffers, 1) else {
            return dropBuffer(endPTS: endPTS)
        }

        let ceiling = max(configuration.maxExtraLeadMicros, 0)
        // The render position is held for a whole cycle, so the arrival's phase within it is unknown. Covering the
        // trim for the worst phase needs one more cycle of lead.
        let neededLead = extraLeadMicros.saturatingAdding(microsFrom(frames: trim))
            .saturatingAdding(max(configuration.escalationMarginMicros, 0))
            .saturatingAdding(microsFrom(frames: Self.cycleFrames(render)))
        clearLateRun()
        // The render-cycle term keeps `neededLead` above the current lead, so an escalation always raises the lead.
        if neededLead <= ceiling {
            extraLeadMicros = neededLead
            stats.extraLeadMicros = neededLead
            stats.leadEscalations += 1
            return resynchronize(endPTS: endPTS, targetMicros: targetMicros, earliest: earliest,
                                 inputFrames: inputFrames, render: render)
        }
        requestClockReanchor()
        return dropBuffer(endPTS: endPTS)
    }

    /// The lead cannot cover sustained lateness. Hold it at the ceiling and ask the caller to re-anchor its clock.
    private mutating func requestClockReanchor() {
        extraLeadMicros = max(configuration.maxExtraLeadMicros, 0)
        stats.extraLeadMicros = extraLeadMicros
        clockReanchorPending = true
        stats.clockReanchors += 1
        ceilingUnderrunPTS.removeAll()
    }

    /// Records one underrun recovery that happened with the lead at its ceiling. The ring keeps the input PTS of the
    /// underruns still inside the window ending at this one. Entries that fell out of the window, or that sit ahead
    /// of this PTS (the source moved backwards), are forgotten. Once the window holds the threshold, sustained
    /// lateness is established, and the clock re-anchor is requested.
    private mutating func recordCeilingUnderrun(ptsMicros: UInt64) {
        // Unsigned arithmetic, so the whole PTS range ages out correctly. Clamping to Int64 would merge the top of it.
        let window = UInt64(max(configuration.ceilingUnderrunWindowMicros, 0))
        ceilingUnderrunPTS.removeAll { ptsMicros < $0 || ptsMicros - $0 > window }
        ceilingUnderrunPTS.append(ptsMicros)
        if ceilingUnderrunPTS.count >= max(configuration.ceilingUnderrunsBeforeReanchor, 1) {
            requestClockReanchor()
        }
    }

    /// Forgets the late-run trend, so the next wholly-late drop starts a new run.
    private mutating func clearLateRun() {
        lateRunTrim = nil
        lateRunTrimBefore = nil
        sustainedLateCount = 0
    }

    /// A dropped buffer leaves the schedule unanchored, so the next buffer re-anchors. That re-anchor is
    /// not counted as a second recovery.
    private mutating func dropBuffer(endPTS: Double) -> AudioPlayoutPlan? {
        stats.droppedBuffers += 1
        nextSample = nil
        lastEndPTS = endPTS
        correcting = false
        return nil
    }

    /// Places the buffer back-to-back at the current schedule, splicing only when the error is
    /// outside the band (or still settling).
    private mutating func contiguous(start: Int64, error: Int64, endPTS: Double,
                                     inputFrames: Int, render: AudioRenderPosition) -> AudioPlayoutPlan? {
        let size = Self.magnitude(error)
        let band = framesFrom(micros: configuration.bandMicros)
        let settle = framesFrom(micros: configuration.settleMicros)
        let crossfade = Int64(max(0, configuration.crossfadeFrames))

        var edit = AudioSpliceEdit.none
        var outputFrames = inputFrames
        if correcting || size > band {
            correcting = true
            if size <= settle {
                correcting = false
            } else {
                let cap = min(framesFrom(micros: configuration.maxSpliceMicros), Int64(inputFrames) - crossfade)
                // A repeat grows the buffer, so also keep `frames + k` representable.
                let room = error > 0 ? cap : min(cap, Int64(Int.max) - Int64(inputFrames))
                let k = min(size, room)
                if k >= 1 {
                    if error > 0 {
                        edit = .skip(frames: Int(k))
                        outputFrames = inputFrames - Int(k)
                    } else {
                        edit = .repeatHead(frames: Int(k))
                        outputFrames = inputFrames + Int(k)
                    }
                }
            }
        }
        guard let plan = commit(start: start, edit: edit, outputFrames: outputFrames,
                                endPTS: endPTS, render: render) else {
            return nil
        }
        stats.lastErrorMicros = microsFrom(frames: error)
        if edit != .none { stats.splices += 1 }
        return plan
    }

    /// Records a returned plan: advances the contiguous schedule and the queue gauge.
    private mutating func commit(start: Int64, edit: AudioSpliceEdit, outputFrames: Int,
                                 endPTS: Double, render: AudioRenderPosition) -> AudioPlayoutPlan? {
        let (end, overflow) = start.addingReportingOverflow(Int64(outputFrames))
        // A buffer whose end is unrepresentable is dropped, so buffer intervals never wrap or overlap.
        guard !overflow else { return dropBuffer(endPTS: endPTS) }
        clearLateRun()  // any returned plan ends the late run
        let follows = queuedEnd == start
        nextSample = end
        queuedEnd = end
        lastEndPTS = endPTS
        stats.scheduledBuffers += 1
        stats.queuedMicros = microsFrom(frames: end.saturatingSubtracting(render.sampleTime))
        return AudioPlayoutPlan(startSample: start, edit: edit, outputFrames: outputFrames,
                                followsQueuedAudio: follows)
    }

    /// Microseconds to frames at the configured rate, rounded to nearest. Clamped before the
    /// conversion so an extreme input cannot trap.
    private func framesFrom(micros: Int64) -> Int64 {
        Self.clampedInt64(Double(micros) * configuration.sampleRate / 1_000_000)
    }

    /// Frames to microseconds at the configured rate, rounded to nearest. Clamped before the
    /// conversion so an extreme input cannot trap.
    private func microsFrom(frames: Int64) -> Int64 {
        Self.clampedInt64(Double(frames) * 1_000_000 / configuration.sampleRate)
    }

    /// Rounds to nearest and clamps into a range well inside Int64, so the conversion never traps.
    private static func clampedInt64(_ value: Double) -> Int64 {
        Int64(min(max(value.rounded(), -9.0e18), 9.0e18))
    }

    /// `abs` that cannot trap on `Int64.min`.
    private static func magnitude(_ value: Int64) -> Int64 {
        value == .min ? .max : abs(value)
    }
}

private extension Int64 {
    func saturatingAdding(_ other: Int64) -> Int64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? (other > 0 ? .max : .min) : sum
    }

    func saturatingSubtracting(_ other: Int64) -> Int64 {
        let (difference, overflow) = subtractingReportingOverflow(other)
        return overflow ? (other > 0 ? .min : .max) : difference
    }
}

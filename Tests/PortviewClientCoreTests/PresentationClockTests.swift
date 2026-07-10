import Testing
import PortviewClientCore

/// PresentationClock maps a host-timeline media PTS to a local-timeline target present time using a
/// signed host-clock offset (convention: host = local + offset, i.e. offset = hostMicros − localMicros)
/// plus a fixed presentation delay (jitter headroom). The mapping is a pure translation, so it is
/// strictly monotonic in PTS for any fixed offset.
@Suite struct PresentationClockTests {
    @Test(arguments: [
        Int64(0), 50_000, -50_000,                 // zero / small ± offsets
        3_600_000_000, -3_600_000_000,             // ±1 hour
        1_000_000_000_000, -1_000_000_000_000,     // ±11.6 days (large)
    ])
    func mappingIsStrictlyMonotonicInPTS(offset: Int64) {
        let clock = PresentationClock(hostClockOffsetMicros: offset)
        let ptsValues: [UInt64] = [0, 1, 999, 33_333, 1_000_000, 16_666_666, 10_000_000_000]
        let targets = ptsValues.map { clock.targetPresentTimeMicros(forPTSMicros: $0) }
        for i in 0..<(targets.count - 1) {
            #expect(targets[i] < targets[i + 1], "pts \(ptsValues[i]) → \(targets[i]) must precede pts \(ptsValues[i + 1]) → \(targets[i + 1]) at offset \(offset)")
        }
    }

    /// Sign convention: host = local + offset. A PTS stamped at host time (local + offset) must map
    /// back to that local instant plus the presentation delay.
    @Test(arguments: [Int64(250_000), -250_000, 0])
    func signConventionHostEqualsLocalPlusOffset(offset: Int64) {
        let localMicros: Int64 = 1_000_000
        let clock = PresentationClock(hostClockOffsetMicros: offset, presentationDelayMicros: 50_000)
        let hostPTS = UInt64(localMicros + offset)
        #expect(clock.targetPresentTimeMicros(forPTSMicros: hostPTS) == localMicros + 50_000)
    }

    @Test func mappingFormula() {
        // Host clock 200ms ahead of local: pts 1_000_000 (host) is local 800_000; +50ms delay.
        let ahead = PresentationClock(hostClockOffsetMicros: 200_000, presentationDelayMicros: 50_000)
        #expect(ahead.targetPresentTimeMicros(forPTSMicros: 1_000_000) == 850_000)
        // Host clock 200ms behind local: pts 1_000_000 (host) is local 1_200_000; +50ms delay.
        let behind = PresentationClock(hostClockOffsetMicros: -200_000, presentationDelayMicros: 50_000)
        #expect(behind.targetPresentTimeMicros(forPTSMicros: 1_000_000) == 1_250_000)
    }

    @Test func defaultPresentationDelayIs50ms() {
        let clock = PresentationClock(hostClockOffsetMicros: 0)
        #expect(clock.presentationDelayMicros == 50_000)
        #expect(clock.targetPresentTimeMicros(forPTSMicros: 1_000_000) == 1_050_000)
    }

    /// The mapping is a translation: PTS spacing is preserved exactly on the local timeline.
    @Test func mappingPreservesPTSDeltas() {
        let clock = PresentationClock(hostClockOffsetMicros: -123_456, presentationDelayMicros: 7_000)
        let t1 = clock.targetPresentTimeMicros(forPTSMicros: 1_500_000)
        let t2 = clock.targetPresentTimeMicros(forPTSMicros: 2_000_000)
        #expect(t2 - t1 == 500_000)
    }

    /// Wire hardening: a corrupt/hostile host PTS (e.g. `UInt64.max` after a normal anchor) maps to
    /// a saturated far-future target; the schedule clamp bounds it to the horizon past `now` so the
    /// downstream hostTime conversion (µs → ns → timebase ticks) can never overflow-trap the client.
    @Test func hostilePTSTargetClampsToTheScheduleHorizon() {
        let clock = PresentationClock(hostClockOffsetMicros: 1_000_000)  // a normal audio anchor
        let now: Int64 = 2_000_000
        let hostileTarget = clock.targetPresentTimeMicros(forPTSMicros: .max)
        #expect(hostileTarget > Int64.max / 1_000)  // near-saturated — unclamped, ×1_000 would trap
        #expect(PresentationClock.clampedScheduleTargetMicros(hostileTarget, now: now)
                == now + PresentationClock.maxScheduleAheadMicros)
    }

    /// Sane targets pass through the clamp unchanged: jitter headroom ahead, past instants (they
    /// just schedule immediately), and exactly the horizon. One microsecond past the horizon clamps.
    @Test func nearbyTargetsPassThroughTheScheduleClampUnchanged() {
        let now: Int64 = 5_000_000
        #expect(PresentationClock.clampedScheduleTargetMicros(5_050_000, now: now) == 5_050_000)
        #expect(PresentationClock.clampedScheduleTargetMicros(4_000_000, now: now) == 4_000_000)
        let horizon = now + PresentationClock.maxScheduleAheadMicros
        #expect(PresentationClock.clampedScheduleTargetMicros(horizon, now: now) == horizon)
        #expect(PresentationClock.clampedScheduleTargetMicros(horizon + 1, now: now) == horizon)
    }

    /// The clamp itself must not trap on an adversarial-extreme `now` (saturating horizon add).
    @Test func scheduleClampSaturatesAtExtremeNow() {
        #expect(PresentationClock.clampedScheduleTargetMicros(.max, now: .max) == .max)
    }
}

/// PTSJitterBuffer: bounded, PTS-ordered staging for media elements awaiting their target present
/// time. Oldest-first (lowest PTS) eviction over capacity; elements more than `lateBudgetMicros`
/// past their target at insert or pop time are dropped and counted in `droppedLate`.
@Suite struct PresentationClockJitterBufferTests {
    /// offset 0, delay 0 → target present time == pts, which keeps the arithmetic readable.
    private let identityClock = PresentationClock(hostClockOffsetMicros: 0, presentationDelayMicros: 0)

    @Test func emptyBufferPopsNothing() {
        var buffer = PTSJitterBuffer<String>(clock: identityClock, capacity: 4, lateBudgetMicros: 1_000)
        #expect(buffer.popDue(now: 0).isEmpty)
        #expect(buffer.isEmpty)
        #expect(buffer.droppedLate == 0)
        #expect(buffer.droppedOverflow == 0)
    }

    @Test func popDrainsAllDueElementsInPTSOrderAndKeepsTheRest() {
        var buffer = PTSJitterBuffer<String>(clock: identityClock, capacity: 8, lateBudgetMicros: 1_000_000)
        for (pts, label) in [(UInt64(30), "p30"), (10, "p10"), (40, "p40"), (20, "p20")] {
            buffer.insert(pts: pts, element: label, now: 0)
        }
        #expect(buffer.popDue(now: 25) == ["p10", "p20"])   // multiple due, drained in PTS order
        #expect(buffer.count == 2)                           // p30/p40 not yet due
        #expect(buffer.popDue(now: 25).isEmpty)              // no double emission
        #expect(buffer.popDue(now: 40) == ["p30", "p40"])
        #expect(buffer.isEmpty)
    }

    /// Interleave two streams' PTS values through one clock in one buffer: pop order is global PTS order.
    @Test func interleavedStreamsPopInGlobalPTSOrder() {
        var buffer = PTSJitterBuffer<String>(clock: identityClock, capacity: 16, lateBudgetMicros: 1_000_000)
        let arrivals: [(UInt64, String)] = [
            (64_000, "A4"), (8_333, "V1"), (21_333, "A2"), (58_333, "V4"),
            (0, "A1"), (41_666, "V3"), (42_666, "A3"), (25_000, "V2"),
        ]
        for (pts, label) in arrivals { buffer.insert(pts: pts, element: label, now: 0) }
        #expect(buffer.popDue(now: 100_000) == ["A1", "V1", "A2", "V2", "V3", "A3", "V4", "A4"])
    }

    /// Two buffers (audio + video instances, as the m-present follow-on will hold them) sharing one
    /// clock emit in global PTS order when each is popped as `now` advances.
    @Test func twoBuffersSharingOneClockEmitInGlobalPTSOrder() {
        let clock = PresentationClock(hostClockOffsetMicros: -250_000, presentationDelayMicros: 50_000)
        var audio = PTSJitterBuffer<String>(clock: clock, capacity: 8, lateBudgetMicros: 1_000)
        var video = PTSJitterBuffer<String>(clock: clock, capacity: 8, lateBudgetMicros: 1_000)
        audio.insert(pts: 10_000, element: "A1", now: 0)
        audio.insert(pts: 30_000, element: "A2", now: 0)
        audio.insert(pts: 50_000, element: "A3", now: 0)
        video.insert(pts: 20_000, element: "V1", now: 0)
        video.insert(pts: 40_000, element: "V2", now: 0)
        video.insert(pts: 60_000, element: "V3", now: 0)

        var emitted: [String] = []
        for pts in [UInt64(10_000), 20_000, 30_000, 40_000, 50_000, 60_000] {
            let now = clock.targetPresentTimeMicros(forPTSMicros: pts)
            emitted += audio.popDue(now: now)
            emitted += video.popDue(now: now)
        }
        #expect(emitted == ["A1", "V1", "A2", "V2", "A3", "V3"])
    }

    @Test func capacityBoundDropsOldestFirst() {
        var buffer = PTSJitterBuffer<String>(clock: identityClock, capacity: 3, lateBudgetMicros: 1_000_000)
        for pts in UInt64(1)...6 {
            buffer.insert(pts: pts, element: "p\(pts)", now: 0)
            #expect(buffer.count <= 3)
        }
        #expect(buffer.droppedOverflow == 3)
        #expect(buffer.popDue(now: 100) == ["p4", "p5", "p6"])  // the three oldest were evicted
    }

    /// Oldest-first eviction can evict the incoming element itself when it carries the lowest PTS.
    @Test func overCapacityInsertOfOldestPTSEvictsTheIncomingElement() {
        var buffer = PTSJitterBuffer<String>(clock: identityClock, capacity: 2, lateBudgetMicros: 1_000_000)
        let kept10 = buffer.insert(pts: 10, element: "p10", now: 0)
        let kept20 = buffer.insert(pts: 20, element: "p20", now: 0)
        let kept5 = buffer.insert(pts: 5, element: "p5", now: 0)
        #expect(kept10)
        #expect(kept20)
        #expect(!kept5)
        #expect(buffer.droppedOverflow == 1)
        #expect(buffer.popDue(now: 100) == ["p10", "p20"])
    }

    @Test func latePastBudgetAtInsertIsDroppedAndCountedOnTimeKept() {
        var buffer = PTSJitterBuffer<String>(clock: identityClock, capacity: 8, lateBudgetMicros: 1_000)
        let keptLate = buffer.insert(pts: 100, element: "late", now: 2_000)     // 1_900 past target
        #expect(!keptLate)
        #expect(buffer.droppedLate == 1)
        let keptOnTime = buffer.insert(pts: 1_500, element: "onTime", now: 2_000)  // only 500 past target
        #expect(keptOnTime)
        #expect(buffer.popDue(now: 2_000) == ["onTime"])
        #expect(buffer.droppedLate == 1)
    }

    @Test func latePastBudgetAtPopIsDroppedAndCountedOnTimeKept() {
        var buffer = PTSJitterBuffer<String>(clock: identityClock, capacity: 8, lateBudgetMicros: 1_000)
        buffer.insert(pts: 100, element: "staleByPopTime", now: 0)   // on time when inserted
        buffer.insert(pts: 4_500, element: "onTime", now: 0)
        #expect(buffer.popDue(now: 5_000) == ["onTime"])             // 100 is now 4_900 past target
        #expect(buffer.droppedLate == 1)
        #expect(buffer.isEmpty)
    }

    /// Boundary: exactly `lateBudget` past the target is NOT "more than" — kept at insert and pop;
    /// one microsecond further is dropped.
    @Test func exactLateBudgetBoundaryIsKeptOneMicroPastIsDropped() {
        var atInsert = PTSJitterBuffer<String>(clock: identityClock, capacity: 8, lateBudgetMicros: 1_000)
        let keptExact = atInsert.insert(pts: 1_000, element: "exact", now: 2_000)  // now − target == budget
        let keptPast = atInsert.insert(pts: 999, element: "past", now: 2_000)      // now − target == budget + 1
        #expect(keptExact)
        #expect(!keptPast)
        #expect(atInsert.popDue(now: 2_000) == ["exact"])
        #expect(atInsert.droppedLate == 1)

        var atPop = PTSJitterBuffer<String>(clock: identityClock, capacity: 8, lateBudgetMicros: 1_000)
        atPop.insert(pts: 1_000, element: "exact", now: 0)
        atPop.insert(pts: 999, element: "past", now: 0)
        #expect(atPop.popDue(now: 2_000) == ["exact"])
        #expect(atPop.droppedLate == 1)
    }

    @Test func equalPTSPreservesInsertionOrder() {
        var buffer = PTSJitterBuffer<String>(clock: identityClock, capacity: 8, lateBudgetMicros: 1_000_000)
        buffer.insert(pts: 100, element: "first", now: 0)
        buffer.insert(pts: 100, element: "second", now: 0)
        #expect(buffer.popDue(now: 200) == ["first", "second"])
    }

    @Test func nextTargetPresentTimeTracksLowestPTS() {
        let clock = PresentationClock(hostClockOffsetMicros: 100_000, presentationDelayMicros: 50_000)
        var buffer = PTSJitterBuffer<String>(clock: clock, capacity: 8, lateBudgetMicros: 1_000_000)
        #expect(buffer.nextTargetPresentTimeMicros == nil)
        buffer.insert(pts: 500_000, element: "late", now: 0)
        buffer.insert(pts: 300_000, element: "early", now: 0)
        #expect(buffer.nextTargetPresentTimeMicros == 250_000)  // 300_000 − 100_000 + 50_000
    }
}

// SPDX-License-Identifier: Apache-2.0
/// How much later than the A/V presentation clock audio has to be scheduled on the current output route.
///
/// The clock's budget (its 50 ms presentation delay plus the scheduler's adaptive lead) was sized on Roshar's
/// built-in speaker, where a rendered sample is heard 24–45 ms later. A high-latency route, such as Bluetooth
/// headphones at ~150–250 ms, hears it far later than that budget allows. Without compensation every buffer's
/// ideal start falls behind the committed-audio floor, every buffer is dropped, and a clock re-anchor recreates
/// the same budget: permanent silence. The compensation is the part of the route's latency (output latency plus
/// one IO buffer) beyond what the speaker-sized budget already absorbs. Audio then lags video by that much
/// extra, which is inherent to such a route. It is zero on the speaker, so nothing changes there.
///
/// The caller reads the route's stable reported figures (`AVAudioSession.outputLatency` and
/// `ioBufferDuration`), not the per-cycle render timestamps: those jitter by a whole render cycle, and a
/// jittering target would trip the scheduler's 8 ms band into needless splices.
public enum AudioRouteLatency {
    /// Route latency (output latency plus one IO buffer) the clock's budget already absorbs: the most measured
    /// from render to ear on Roshar's built-in speaker.
    public static let absorbedMicros: Int64 = 45_000

    /// Extra delay (µs) to add to the clock target on this route. Zero for non-finite or non-positive inputs and
    /// on routes no slower than the speaker; never more than 10 s.
    public static func compensationMicros(outputLatency: Double, ioBufferDuration: Double) -> Int64 {
        let seconds = max(outputLatency.isFinite ? outputLatency : 0, 0)
            + max(ioBufferDuration.isFinite ? ioBufferDuration : 0, 0)
        let micros = Int64((min(seconds, 10) * 1_000_000).rounded())
        return max(0, micros - absorbedMicros)
    }
}

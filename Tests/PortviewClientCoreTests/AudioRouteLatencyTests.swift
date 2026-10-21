// SPDX-License-Identifier: Apache-2.0
import Testing
import PortviewClientCore

/// AudioRouteLatency delays audio on routes slower than the built-in speaker the clock's budget was sized on, by
/// exactly the excess, and never on the speaker itself.
@Suite struct AudioRouteLatencyTests {
    @Test func speakerRouteNeedsNoCompensation() {
        // A speaker-class route: a few ms of output latency plus a 1,024-frame IO buffer at 48 kHz.
        #expect(AudioRouteLatency.compensationMicros(outputLatency: 0.010, ioBufferDuration: 0.021_333) == 0)
        #expect(AudioRouteLatency.compensationMicros(outputLatency: 0.023_667, ioBufferDuration: 0.021_333) == 0)
    }

    @Test func slowRouteIsCompensatedByItsExcessOverTheSpeakerBudget() {
        // Bluetooth-class: 180 ms output latency plus the IO buffer, minus the 45 ms the clock's budget absorbs.
        #expect(AudioRouteLatency.compensationMicros(outputLatency: 0.180, ioBufferDuration: 0.021_333) == 156_333)
    }

    @Test func malformedOrExtremeInputsAreBounded() {
        #expect(AudioRouteLatency.compensationMicros(outputLatency: .nan, ioBufferDuration: .infinity) == 0)
        #expect(AudioRouteLatency.compensationMicros(outputLatency: -1, ioBufferDuration: -1) == 0)
        #expect(AudioRouteLatency.compensationMicros(outputLatency: 1e9, ioBufferDuration: 0)
                == 10_000_000 - AudioRouteLatency.absorbedMicros)
    }
}

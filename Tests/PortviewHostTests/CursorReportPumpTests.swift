// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import PortviewHostCore

/// The ordered cursor-report lane: confirmations are delivered in monotonic order (never back-stepped
/// by an out-of-order detached send) and the latest position always wins under coalescing.
@Suite struct CursorReportPumpTests {
    private actor Recorder {
        private(set) var xs: [Double] = []
        func append(_ x: Double) { xs.append(x) }
        func snapshot() -> [Double] { xs }
        func last() -> Double? { xs.last }
    }

    @Test func reportsDrainInOrderAndLatestAlwaysWins() async {
        let recorder = Recorder()
        let pump = CursorReportPump(sink: { nx, _ in await recorder.append(nx) })

        // A burst of increasing positions (a sustained pan). Whatever coalescing does, the delivered
        // values must be non-decreasing (no back-step) and end on the latest reported value.
        for i in 1...50 { pump.report(Double(i), 0) }

        for _ in 0..<200 {
            if await recorder.last() == 50 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let values = await recorder.snapshot()
        #expect(values.last == 50)                 // latest wins
        #expect(values == values.sorted())         // monotonic: never reordered/back-stepped
        #expect(!values.isEmpty)
        pump.finish()
    }

    @Test func eachReportIsDeliveredWhenDrainKeepsUp() async {
        let recorder = Recorder()
        let pump = CursorReportPump(sink: { nx, _ in await recorder.append(nx) })

        // Space the reports out so the single drain empties between each — every distinct value lands.
        for i in 1...5 {
            pump.report(Double(i), 0)
            try? await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<200 {
            if await recorder.last() == 5 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await recorder.snapshot() == [1, 2, 3, 4, 5])
        pump.finish()
    }
}

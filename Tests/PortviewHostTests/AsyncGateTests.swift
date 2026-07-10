// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
@testable import PortviewHostCore

/// `AsyncGate` FIFO mutex: sections holding the gate never overlap — even across suspension
/// points, which `NSLock` cannot cover — and every waiter is eventually admitted.
@Suite struct AsyncGateTests {
    private final class Overlap: @unchecked Sendable {
        private let lock = NSLock()
        private var inside = 0
        private var peak = 0
        func enter() { lock.lock(); inside += 1; peak = max(peak, inside); lock.unlock() }
        func exit() { lock.lock(); inside -= 1; lock.unlock() }
        var maxConcurrency: Int { lock.lock(); defer { lock.unlock() }; return peak }
    }

    @Test func sectionsWithSuspensionPointsNeverOverlap() async {
        let gate = AsyncGate()
        let overlap = Overlap()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    await gate.enter()
                    overlap.enter()
                    // A suspension point INSIDE the held section — the case a plain lock can't guard.
                    try? await Task.sleep(for: .milliseconds(2))
                    overlap.exit()
                    gate.leave()
                }
            }
        }
        #expect(overlap.maxConcurrency == 1)
    }

    @Test func uncontendedGateAdmitsImmediatelyAndReusably() async {
        let gate = AsyncGate()
        await gate.enter()
        gate.leave()
        await gate.enter()
        gate.leave()
    }
}

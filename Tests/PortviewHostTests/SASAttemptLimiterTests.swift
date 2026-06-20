import Testing
import Foundation
@testable import PortviewHostCore

@Suite struct SASAttemptLimiterTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func closedByDefault() {
        var l = SASAttemptLimiter()
        #expect(!l.isOpen(now: t0))
        let allowed = l.registerAttempt(now: t0)
        #expect(allowed == false)  // no attempts allowed while closed
    }

    @Test func opensThenExpiresAfterWindow() {
        var l = SASAttemptLimiter(windowDuration: 120, maxAttempts: 5)
        l.open(now: t0)
        #expect(l.isOpen(now: t0))
        #expect(l.isOpen(now: t0.addingTimeInterval(119)))
        #expect(!l.isOpen(now: t0.addingTimeInterval(120)))   // boundary: exactly at duration → closed
        #expect(!l.isOpen(now: t0.addingTimeInterval(121)))
    }

    @Test func attemptsAllowedUpToCapThenRejected() {
        var l = SASAttemptLimiter(windowDuration: 120, maxAttempts: 3)
        l.open(now: t0)
        let r1 = l.registerAttempt(now: t0)   // 1
        let r2 = l.registerAttempt(now: t0)   // 2
        let r3 = l.registerAttempt(now: t0)   // 3 (== cap, still ok)
        let r4 = l.registerAttempt(now: t0)   // 4 (exceeds cap)
        let r5 = l.registerAttempt(now: t0)   // stays rejected
        #expect([r1, r2, r3] == [true, true, true])
        #expect(r4 == false)
        #expect(r5 == false)
    }

    @Test func attemptAfterExpiryIsRejected() {
        var l = SASAttemptLimiter(windowDuration: 120, maxAttempts: 5)
        l.open(now: t0)
        let inWindow = l.registerAttempt(now: t0)
        let afterExpiry = l.registerAttempt(now: t0.addingTimeInterval(200))
        #expect(inWindow)
        #expect(afterExpiry == false)
    }

    @Test func reopenResetsAttempts() {
        var l = SASAttemptLimiter(windowDuration: 120, maxAttempts: 2)
        l.open(now: t0)
        _ = l.registerAttempt(now: t0)
        _ = l.registerAttempt(now: t0)
        let capped = l.registerAttempt(now: t0)        // over cap
        l.open(now: t0.addingTimeInterval(300))         // user re-opens
        let afterReopen = l.registerAttempt(now: t0.addingTimeInterval(300))
        #expect(capped == false)
        #expect(afterReopen)                            // fresh budget
    }

    @Test func closeStopsAttempts() {
        var l = SASAttemptLimiter(windowDuration: 120, maxAttempts: 5)
        l.open(now: t0)
        let before = l.registerAttempt(now: t0)
        l.close()
        let openAfterClose = l.isOpen(now: t0)
        let after = l.registerAttempt(now: t0)
        #expect(before)
        #expect(!openAfterClose)
        #expect(after == false)
    }
}

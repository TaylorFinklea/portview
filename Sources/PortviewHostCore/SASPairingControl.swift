import Foundation

/// Pure, value-type pairing-window + attempt cap for SAS pairing (injected `now` for testability).
/// The window is opened by the user (a "Pair" action) and auto-expires; while open, each preamble
/// engagement counts as one attempt. Exceeding `maxAttempts` signals the caller to close the window —
/// a hard ceiling on online ~1/10⁶ guesses that a future timing trick can't out-pace. Scoped to the
/// open window so a remote attacker can't lock out a user who isn't currently pairing.
public struct SASAttemptLimiter: Sendable {
    public let windowDuration: TimeInterval
    public let maxAttempts: Int
    private var windowStart: Date?
    private var attempts: Int = 0

    public init(windowDuration: TimeInterval = 120, maxAttempts: Int = 5) {
        self.windowDuration = windowDuration
        self.maxAttempts = maxAttempts
    }

    public mutating func open(now: Date) { windowStart = now; attempts = 0 }
    public mutating func close() { windowStart = nil; attempts = 0 }

    public func isOpen(now: Date) -> Bool {
        guard let windowStart else { return false }
        return now.timeIntervalSince(windowStart) < windowDuration
    }

    /// Record one pairing attempt. Returns true if still within the cap, false once the cap is
    /// exceeded (the caller should close the window). A no-op `false` if the window isn't open.
    public mutating func registerAttempt(now: Date) -> Bool {
        guard isOpen(now: now) else { return false }
        attempts += 1
        return attempts <= maxAttempts
    }
}

/// Actor-isolated holder around `SASAttemptLimiter`, shared between the host app (which opens/closes
/// the window on user action) and the serve loop (which checks the window + counts attempts). All
/// callers are already in async contexts, so actor isolation replaces the hand-rolled lock.
public actor SASPairingControl {
    private var limiter: SASAttemptLimiter

    public init(windowDuration: TimeInterval = 120, maxAttempts: Int = 5) {
        limiter = SASAttemptLimiter(windowDuration: windowDuration, maxAttempts: maxAttempts)
    }

    /// User opened the pairing window (e.g. tapped "Pair" on the host).
    public func openWindow(now: Date = Date()) { limiter.open(now: now) }
    public func closeWindow() { limiter.close() }

    func isOpen(now: Date = Date()) -> Bool { limiter.isOpen(now: now) }
    func registerAttempt(now: Date = Date()) -> Bool { limiter.registerAttempt(now: now) }
}

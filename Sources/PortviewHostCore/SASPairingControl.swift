import Foundation
import Network

/// Pure, value-type pairing-window + attempt caps for SAS pairing (injected `now` for testability).
/// The window is opened by the user (a "Pair" action) and auto-expires; while open, each preamble
/// engagement counts as one attempt against its remote SOURCE. Attempts are tracked per source so a
/// flooding source exhausts only its own `maxAttempts` budget (it gets rejected; the window stays
/// open for other sources) instead of tripping a shared counter and denying the legit device. A
/// window-scoped `maxTotalAttempts` ceiling across ALL sources remains the hard bound on online
/// ~1/10⁶ guesses — a source-rotating attacker gets at most that budget, after which the window
/// closes. Scoped to the open window so a remote attacker can't lock out a user who isn't
/// currently pairing.
public struct SASAttemptLimiter: Sendable {
    public let windowDuration: TimeInterval
    /// Per-source attempt cap: a single grinder is rejected past this, without affecting others.
    public let maxAttempts: Int
    /// Window-wide ceiling across all sources; exhausting it closes the window (hard guess bound).
    public let maxTotalAttempts: Int
    private var windowStart: Date?
    private var attemptsBySource: [String: Int] = [:]
    private var totalAttempts: Int = 0

    public init(windowDuration: TimeInterval = 120, maxAttempts: Int = 5, maxTotalAttempts: Int = 20) {
        self.windowDuration = windowDuration
        self.maxAttempts = maxAttempts
        self.maxTotalAttempts = maxTotalAttempts
    }

    public mutating func open(now: Date) { windowStart = now; attemptsBySource = [:]; totalAttempts = 0 }
    public mutating func close() { windowStart = nil; attemptsBySource = [:]; totalAttempts = 0 }

    public func isOpen(now: Date) -> Bool {
        guard let windowStart else { return false }
        return now.timeIntervalSince(windowStart) < windowDuration
    }

    /// Record one pairing attempt from `source`. Returns true if the attempt is allowed; false when
    /// the window isn't open, when `source` is past its per-source cap (only that source is rejected
    /// — its over-cap flood must neither close the window nor burn the shared budget), or when the
    /// window-wide `maxTotalAttempts` ceiling is exhausted (which closes the window: rotating
    /// sources must not yield unbounded guesses). The bookkeeping stays bounded — a new source only
    /// enters the map via an attempt that counts against the total, so at most `maxTotalAttempts`+1
    /// sources are ever tracked per window.
    public mutating func registerAttempt(source: String, now: Date) -> Bool {
        guard isOpen(now: now) else { return false }
        let sourceAttempts = attemptsBySource[source, default: 0] + 1
        attemptsBySource[source] = sourceAttempts
        guard sourceAttempts <= maxAttempts else { return false }
        totalAttempts += 1
        guard totalAttempts <= maxTotalAttempts else { close(); return false }
        return true
    }
}

/// Actor-isolated holder around `SASAttemptLimiter`, shared between the host app (which opens/closes
/// the window on user action) and the serve loop (which checks the window + counts attempts). All
/// callers are already in async contexts, so actor isolation replaces the hand-rolled lock.
public actor SASPairingControl {
    private var limiter: SASAttemptLimiter

    public init(windowDuration: TimeInterval = 120, maxAttempts: Int = 5, maxTotalAttempts: Int = 20) {
        limiter = SASAttemptLimiter(windowDuration: windowDuration, maxAttempts: maxAttempts,
                                    maxTotalAttempts: maxTotalAttempts)
    }

    /// User opened the pairing window (e.g. tapped "Pair" on the host).
    public func openWindow(now: Date = Date()) { limiter.open(now: now) }
    public func closeWindow() { limiter.close() }

    func isOpen(now: Date = Date()) -> Bool { limiter.isOpen(now: now) }
    func registerAttempt(source: String, now: Date = Date()) -> Bool {
        limiter.registerAttempt(source: source, now: now)
    }

    /// Per-source key for the attempt limiter: the connection's resolved remote HOST (IP), dropping
    /// the port — a client's source port rotates on every QUIC dial (keying on it would mint a
    /// flooder a fresh budget per connection), while the IP is the stablest pre-pairing per-device
    /// key available. Unresolved/non-hostPort endpoints share a single bucket.
    static func sourceKey(for endpoint: NWEndpoint?) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "unresolved" }
        return String(describing: host)
    }
}

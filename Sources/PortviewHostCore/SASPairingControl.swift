// SPDX-License-Identifier: Apache-2.0
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
    /// Owner token of whichever preamble currently holds the HUD's single code-display slot — an
    /// opaque LEASE, not a slot-holder identity. Only the current token's holder may display its
    /// derived code, so a second concurrent preamble (must-fix 6) fails to claim and must close its
    /// connection before the host ever reveals its nonce to it. `openWindow()` can force-release
    /// this out from under a live holder (stale-claim recovery); the stripped holder does NOT get
    /// evicted directly — it must observe the loss itself via `holdsCodeDisplay(token:)` before it
    /// acts on the slot again (in particular, immediately before displaying its code).
    private var codeDisplayOwner: UInt64?
    /// Monotonically incrementing source of fresh owner tokens. Deliberately NOT derived from
    /// `source`: link-local/APIPA bucketing (`linkLocalIPv4Bucket`) and IPv6 /64 bucketing both
    /// let distinct connections share one source key, so a source-derived token could collide
    /// across them and let an unrelated connection mistake itself for the current lease holder.
    private var nextCodeDisplayToken: UInt64 = 0

    public init(windowDuration: TimeInterval = 120, maxAttempts: Int = 5, maxTotalAttempts: Int = 20) {
        limiter = SASAttemptLimiter(windowDuration: windowDuration, maxAttempts: maxAttempts,
                                    maxTotalAttempts: maxTotalAttempts)
    }

    /// User opened the pairing window (e.g. tapped "Pair" on the host). Force-releases any
    /// code-display lease left over from a previous window — a connection that never reached its
    /// release (crash, forced close) must not wedge every future window's display slot shut. This
    /// does not reach into the stripped holder and stop it; that connection keeps running and must
    /// notice the loss on its own via `holdsCodeDisplay(token:)`.
    public func openWindow(now: Date = Date()) { limiter.open(now: now); codeDisplayOwner = nil }
    public func closeWindow() { limiter.close() }

    func isOpen(now: Date = Date()) -> Bool { limiter.isOpen(now: now) }
    func registerAttempt(source: String, now: Date = Date()) -> Bool {
        limiter.registerAttempt(source: source, now: now)
    }

    /// Claim the HUD's single code-display slot for `source`, returning a fresh owner token on
    /// success, or nil if another connection already holds the lease. `source` does not shape the
    /// token (see `nextCodeDisplayToken`); it exists only so callers key the claim off the same
    /// value they already derived for attempt-limiting. Callers must acquire this BEFORE sending
    /// the host's SAS reveal, so a losing concurrent preamble closes its connection before its peer
    /// ever derives a code that isn't the one displayed — and must re-validate with
    /// `holdsCodeDisplay(token:)` immediately before actually displaying the code, since a
    /// subsequent `openWindow()` can force-release this lease at any time after it's granted.
    func claimCodeDisplay(source: String) -> UInt64? {
        guard codeDisplayOwner == nil else { return nil }
        nextCodeDisplayToken += 1
        codeDisplayOwner = nextCodeDisplayToken
        return nextCodeDisplayToken
    }

    /// Release the code-display lease if `token` is its current owner; a stale or non-owner token
    /// is a no-op so a connection that already lost the lease (e.g. via `openWindow()`) — or a late
    /// duplicate release — can't evict whoever holds the slot now.
    func releaseCodeDisplay(token: UInt64) {
        guard codeDisplayOwner == token else { return }
        codeDisplayOwner = nil
    }

    /// True iff `token` is still the current code-display lease holder. The one call site that
    /// matters is `serveSASPreamble`, immediately before `emit(.sasCode(...))`: a lease acquired
    /// earlier in that function can have been force-released by an intervening `openWindow()`
    /// (e.g. while this connection was blocked awaiting the client's reveal), and a stripped holder
    /// must skip the emit rather than trust its now-stale token.
    func holdsCodeDisplay(token: UInt64) -> Bool {
        codeDisplayOwner == token
    }

    /// Per-source key for the attempt limiter: the connection's resolved remote HOST (IP), dropping
    /// the port — a client's source port rotates on every QUIC dial (keying on it would mint a
    /// flooder a fresh budget per connection), while the IP is the stablest pre-pairing per-device
    /// key available. IPv4 keys on the address itself (shared-NAT peers sharing a budget stays an
    /// accepted caveat). IPv6 keys on the address's /64 prefix — the standard on-link subnet —
    /// because one machine can self-assign many addresses within its /64 (SLAAC/privacy
    /// addressing, no NAT), each of which would otherwise mint a fresh per-source budget.
    /// Zone/scope identifiers are STRIPPED: the prefix is taken from the bare address bytes
    /// (`IPv6Address.rawValue` carries no zone — it lives in `.interface`), so two addresses
    /// differing only in scope bucket together. IPv4-mapped/compatible IPv6 (dual-stack listeners
    /// surface v4 peers as ::ffff:a.b.c.d, whose upper 64 bits are all zero) keys as its embedded
    /// IPv4 address rather than collapsing every v4 client into one all-zeros /64 bucket. IPv4
    /// addresses in 169.254.0.0/16 (APIPA — self-assigned when DHCP fails) all bucket into one
    /// shared key: many distinct devices on a segment can each mint one, so per-address keying
    /// would hand each an independent budget instead of the single-source-class treatment they
    /// warrant. This link-local bucketing applies equally to the embedded IPv4 address extracted
    /// from a mapped IPv6 peer (::ffff:169.254.x.x) — otherwise a dual-stack listener's view of an
    /// APIPA peer would bypass the bucket and mint it a private per-address budget. Unresolved/
    /// non-hostPort endpoints share a single bucket.
    static func sourceKey(for endpoint: NWEndpoint?) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "unresolved" }
        if case .ipv6(let address) = host {
            if let v4 = address.asIPv4 {
                if isLinkLocalIPv4(v4) { return linkLocalIPv4Bucket }
                return String(describing: NWEndpoint.Host.ipv4(v4))
            }
            let prefix = [UInt8](address.rawValue.prefix(8))
            let groups = stride(from: 0, to: 8, by: 2).map {
                String(format: "%x", UInt16(prefix[$0]) << 8 | UInt16(prefix[$0 + 1]))
            }
            return groups.joined(separator: ":") + "::/64"
        }
        if case .ipv4(let address) = host, isLinkLocalIPv4(address) { return linkLocalIPv4Bucket }
        return String(describing: host)
    }

    private static let linkLocalIPv4Bucket = "169.254.0.0/16"

    private static func isLinkLocalIPv4(_ address: IPv4Address) -> Bool {
        let bytes = [UInt8](address.rawValue)
        return bytes.count == 4 && bytes[0] == 169 && bytes[1] == 254
    }
}

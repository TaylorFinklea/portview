// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The client's persisted CloudKit re-wake state (spec: `docs/superpowers/specs/2026-07-01-cloudkit-rewake.md`
/// §3): the per-host dedupe/rate-limit maps `ReWakeDecision.evaluate` consumes, plus the zone
/// change token the background fetch resumes from. Pure codec — the app edge stores the encoded
/// JSON in UserDefaults (mirroring `SavedHostsStore`'s persistence idiom); no I/O here.
public struct ReWakeState: Codable, Equatable, Sendable {
    /// Per-host map (keyed by the beacon's `recordName`, the host pin fingerprint hex) of the epoch
    /// last acted on — the dedupe/replay guard's memory. MUST stay per-host, never a scalar (spec
    /// §3: one Mac's large epoch must not suppress another's wakes).
    public var lastHandledEpochs: [String: Int64]
    /// Per-host map (same key) of when THIS client last acted, on its own wall clock — feeds the
    /// rate limit (see `ReWakeDecision.evaluate`'s `lastActedAt` contract). Deliberately separate
    /// from the epoch map: epochs are the host's opaque ordering values, never client timestamps.
    public var lastActedAt: [String: Date]
    /// Archived `CKServerChangeToken` for the `PortviewSignals` zone fetch; nil = fetch from scratch.
    public var changeTokenData: Data?
    /// Whether the one-time `UNUserNotificationCenter` authorization request has been made (spec
    /// §2a.5: request once, at pairing / first enable — never re-prompt).
    public var didRequestNotificationAuth: Bool
    /// Whether the one-time "notifications are denied so re-wake is inert" passive hint has been
    /// surfaced (spec §2a.5 / failure-modes table: one hint, never blocking).
    public var didShowDeniedHint: Bool

    public init(
        lastHandledEpochs: [String: Int64] = [:],
        lastActedAt: [String: Date] = [:],
        changeTokenData: Data? = nil,
        didRequestNotificationAuth: Bool = false,
        didShowDeniedHint: Bool = false
    ) {
        self.lastHandledEpochs = lastHandledEpochs
        self.lastActedAt = lastActedAt
        self.changeTokenData = changeTokenData
        self.didRequestNotificationAuth = didRequestNotificationAuth
        self.didShowDeniedHint = didShowDeniedHint
    }

    /// Records that the client ACTED on `beacon` at `now` — updates BOTH per-host maps together, as
    /// `ReWakeDecision.evaluate`'s caller contract requires (epoch for the dedupe/replay guard,
    /// wall-clock stamp for the rate limit). Acting = running the reachability probe, regardless of
    /// its outcome — a burst of pushes must not re-probe the same beacon.
    public mutating func markActed(on beacon: HostBeaconRecord, at now: Date) {
        lastHandledEpochs[beacon.recordName] = beacon.epoch
        lastActedAt[beacon.recordName] = now
    }

    /// Tolerant decode: nil or corrupt data yields a fresh empty state (same forgiving posture as
    /// `SavedHostsStore.load()` — persistence problems must never break the feature loudly).
    public static func decoded(from data: Data?) -> ReWakeState {
        guard let data, let state = try? JSONDecoder().decode(ReWakeState.self, from: data) else {
            return ReWakeState()
        }
        return state
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}

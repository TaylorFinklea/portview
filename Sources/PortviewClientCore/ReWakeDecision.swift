import Foundation

/// Pure decode/encode of the CloudKit `HostBeacon` record's field VALUES (spec:
/// `docs/superpowers/specs/2026-07-01-cloudkit-rewake.md` §3). No CloudKit import here — CK types
/// stay at the app edge, which decodes a real `CKRecord`'s fields into this struct (and encodes it
/// back) so the mapping is unit-testable without CloudKit.
public struct HostBeaconRecord: Equatable, Sendable {
    /// The record's identity — `CKRecord.recordName`, the host's pin fingerprint hex (the same
    /// durable identity `SavedHostsStore` dedupes saved hosts on:
    /// `apps/PortviewClient/Sources/SavedHostsStore.swift:43`, `SavedHost.pinHex`). NOT itself a CK
    /// field — `CKRecord.recordName` is assigned via the record's `CKRecord.ID` at creation, not
    /// stored in its fields dictionary — so it travels alongside the field values here rather than
    /// being decoded from (or encoded into) them.
    public var recordName: String
    /// Bonjour/display name of the host.
    public var hostName: String
    /// The host's current persisted listening port.
    public var port: Int64
    /// Monotonic wall-clock epoch (`Date().timeIntervalSince1970` in micros) or a persisted counter —
    /// NEVER host uptime (spec §1: uptime resets to ~0 on reboot, which would make the dedupe below
    /// silently discard every legitimate wake for days after a restart).
    public var epoch: Int64
    /// 0/1: whether this beacon is an explicit "ask iPhone to reconnect" nudge (1) vs a routine
    /// liveness update (0 — hosting start, persisted-port change).
    public var wantsReconnect: Int64

    public init(recordName: String, hostName: String, port: Int64, epoch: Int64, wantsReconnect: Int64) {
        self.recordName = recordName
        self.hostName = hostName
        self.port = port
        self.epoch = epoch
        self.wantsReconnect = wantsReconnect
    }

    /// Decode a `CKRecord`'s field dictionary at the app edge. `recordName` travels separately (see
    /// above) rather than being read out of `fields`. Nil if a required field is missing or isn't the
    /// expected CK-native type.
    public init?(recordName: String, fields: [String: Any]) {
        guard let hostName = fields["hostName"] as? String,
              let port = fields["port"] as? Int64,
              let epoch = fields["epoch"] as? Int64,
              let wantsReconnect = fields["wantsReconnect"] as? Int64 else { return nil }
        self.init(recordName: recordName, hostName: hostName, port: port, epoch: epoch, wantsReconnect: wantsReconnect)
    }

    /// Inverse of `init(recordName:fields:)` — the field VALUES to assign onto a `CKRecord` at the
    /// app edge (`recordName` excluded; it's set via the record's `CKRecord.ID`, not its fields).
    public var fields: [String: Any] {
        ["hostName": hostName, "port": port, "epoch": epoch, "wantsReconnect": wantsReconnect]
    }
}

/// Decides what (if anything) to do with an incoming `HostBeacon` change, per spec §3. Pure — no
/// CloudKit, no networking, no I/O — so the policy is fully unit-testable without a device or
/// CloudKit account.
public enum ReWakeDecision {
    /// Minimum wall-clock spacing between two "act" outcomes for the same host (identified by
    /// `HostBeaconRecord.recordName`) — guards against a burst of beacon writes (rapid restarts,
    /// repeated manual nudges) spamming the phone with reachability probes for one Mac. Applies
    /// uniformly to nudge and routine beacons alike (unlike the epoch dedupe below, which a nudge
    /// bypasses) — repeated manual clicks shouldn't spam notifications either.
    public static let minActInterval: TimeInterval = 30

    /// The saved-host info `evaluate` needs to recognize a beacon and build a probe endpoint —
    /// mirrors the app-level `SavedHost` (`apps/PortviewClient/Sources/SavedHostsStore.swift`)
    /// without creating a package→app dependency; the app maps its `SavedHost` entries into this
    /// shape at the call site.
    public struct SavedHost: Equatable, Sendable {
        /// Durable host identity — matches `HostBeaconRecord.recordName` (the pin fingerprint hex).
        public var pinHex: String
        /// Saved address to dial for the reachability probe (the app edge prefers a live Bonjour
        /// re-resolve over this stale saved address per the spec's DHCP-move caveat — that
        /// resolution happens outside this pure core).
        public var host: String

        public init(pinHex: String, host: String) {
            self.pinHex = pinHex
            self.host = host
        }
    }

    /// A dialable target for the reachability probe: the saved host's address paired with the
    /// beacon's freshly-reported port (the port can change between beacons; the address never
    /// travels on the beacon itself).
    public struct Endpoint: Equatable, Sendable {
        public var host: String
        public var port: Int64

        public init(host: String, port: Int64) {
            self.host = host
            self.port = port
        }
    }

    public enum Action: Equatable, Sendable {
        case ignore
        /// Dial `endpoint` (pinned to `pin`) to confirm the host is actually reachable before ever
        /// promising the user a working resume — "a notification that leads to a dead host is worse
        /// than none" (spec §2 step 3). Resolving a successful probe into a user-visible `.notify`
        /// happens at the app edge (bead rewake-client); this pure decision never skips the probe.
        case reachabilityProbe(endpoint: Endpoint, pin: String)
        case notify(hostName: String)
    }

    /// - Parameters:
    ///   - beacon: the incoming (already-decoded) beacon record.
    ///   - savedHosts: the user's paired Macs; a beacon whose `recordName` isn't among them is an
    ///     unknown host and is ignored outright.
    ///   - lastHandledEpochs: per-host map (keyed by `recordName`, i.e. the pin fingerprint hex) of
    ///     the epoch this host was last acted on for. MUST be per-host, never a scalar — a single
    ///     value would let the Mac with the largest epoch permanently suppress every other saved
    ///     Mac's wakes. The caller persists this map and updates `lastHandledEpochs[beacon.recordName]
    ///     = beacon.epoch` after acting on a beacon (not this function's job — it is pure/stateless).
    ///   - now: wall-clock time of this evaluation, used for the rate limit below.
    public static func evaluate(
        beacon: HostBeaconRecord,
        savedHosts: [SavedHost],
        lastHandledEpochs: [String: Int64],
        now: Date
    ) -> Action {
        guard let saved = savedHosts.first(where: { $0.pinHex == beacon.recordName }) else {
            return .ignore
        }

        let isNudge = beacon.wantsReconnect != 0
        let previousEpoch = lastHandledEpochs[beacon.recordName]

        // Epoch dedupe/replay guard — routine updates only. An explicit nudge is never dropped just
        // because its epoch reads stale (e.g. a host-clock/counter regression after a reboot) — the
        // dedupe must never eat a nudge.
        if !isNudge, let previousEpoch, beacon.epoch <= previousEpoch {
            return .ignore
        }

        // Per-host rate limit: real wall-clock spacing since we last acted for THIS host, independent
        // of the epoch dedupe above.
        if let previousEpoch {
            let previousHandled = Date(timeIntervalSince1970: Double(previousEpoch) / 1_000_000)
            if now.timeIntervalSince(previousHandled) < minActInterval {
                return .ignore
            }
        }

        return .reachabilityProbe(endpoint: Endpoint(host: saved.host, port: beacon.port), pin: saved.pinHex)
    }
}

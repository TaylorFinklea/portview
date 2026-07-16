// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Pure decode/encode of the CloudKit `HostBeacon` record's field VALUES (spec:
/// `docs/superpowers/specs/2026-07-01-cloudkit-rewake.md` §3). No CloudKit import here — CK types
/// stay at the app edges, which decode a real `CKRecord`'s fields into this struct (and encode it
/// back) so the mapping is unit-testable without CloudKit. Lives in `PortviewProtocol` because it
/// is the one record schema BOTH ends share: the host's beacon writer upserts it, the client's
/// re-wake decision consumes it — neither core should depend on the other for it.
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

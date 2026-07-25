// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The canonical device id for a client key: `SHA256(publicKey)` hex (= `PairingStore.deviceID`).
/// Stable for a device's whole lifetime — the same physical device re-enrolled with the same keypair
/// keeps the same `ClientKeyID`, which is exactly why revoke can't reason from identity alone and
/// needs the per-key generation (design §3).
public typealias ClientKeyID = String

/// A registered session's per-connection id (a fresh UUID string per accepted connection, NOT the
/// device's stable key id — so a reconnect's teardown can never evict the new session's entry).
typealias SessionID = String

/// The authority a session captured **at authorization** (inside `serveAuthGate`, immediately after
/// signature verify and before the durable lookup — design §3, Order-A). Immutable and carried
/// by-value through `register`; the whole point of finding 1 is that the generation reflects the
/// authorization instant, never the (much later) register instant.
///
/// A `nil` `keyID` marks a legacy bootstrap-admitted session (no device key proven): it skips the
/// fence/generation check at register and is governed by `evictLegacyAdmitted` instead of revoke.
struct AdmissionTicket: Sendable {
    let keyID: ClientKeyID?
    let generation: UInt64
}

/// The verdict `HostControl.register` returns: `.rejected` when a keyed ticket hits the revoke fence
/// or carries a stale generation (its admission predates a revoke bump), `.admitted` otherwise.
enum AdmissionResult: Sendable, Equatable {
    case admitted
    case rejected
}

/// An opaque, monotonically-minted token that owns one revoke operation for a key (design §4, H-c).
/// `beginRevoke` mints it and sets it as the key's fence; `endRevoke`/`cancelRevoke` require the
/// **matching** lease to lift the fence, so a stale lease (from a superseded revoke) can never lift a
/// newer operation's fence. Comparable/Equatable over an internal id — the raw value never escapes
/// the module, so callers can only hold, compare, and hand it back.
public struct RevokeLease: Sendable, Comparable {
    let id: UInt64

    public static func < (lhs: RevokeLease, rhs: RevokeLease) -> Bool { lhs.id < rhs.id }
}

/// What `beginRevoke` returns to its orchestrator (`HostAppModel.revoke`) so it can drive
/// end/retain/cancel **without** touching the private `Session`/`OutboundLane` (M-b). `lease` is the
/// token required to lift the fence; `evictedCount` is how many live sessions this begin tore down
/// (0 for a coalesced duplicate begin or a key with no live sessions).
public struct RevokeReceipt: Sendable {
    public let lease: RevokeLease
    public let evictedCount: Int
}

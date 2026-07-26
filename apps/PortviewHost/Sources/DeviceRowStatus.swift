// SPDX-License-Identifier: Apache-2.0
import Foundation

// The paired-device surface's decision logic, factored OUT of `HostAppModel` (Sol pass 4 F2/F3).
// `HostAppModel` is `@MainActor` and reaches for `LAContext`, the keychain and `HostControl`, so the
// state machine that decides what a row IS, what it may SAY, and which recovery actions it may offer
// was effectively untestable inside it — and every finding in review cycles 3–5, including a security
// regression, lived in exactly that logic. Everything here is pure, `Foundation`-only and injectable;
// it is a SEAM THAT EXPOSES STATE, NOT ONE THAT GRANTS AUTHORITY: the confirmation dialog stays in the
// view and the `LAContext` gate stays in `HostAppModel`, and nothing in this file can perform, skip or
// weaken either. `RecoveryAction` only DESCRIBES which gates an action owes.

/// What is KNOWN about the durability of an incomplete revoke's fence — the UI half of
/// `RevokeIncomplete`'s three-way split (design §1a step 5, §7 invariant 6b; Sol pass 3 N1).
/// A device is in the model's warning map only while a warning is warranted; a proven-durable fence
/// is the ABSENCE of an entry.
enum RevokeDurabilityWarning: Sendable, Equatable, CaseIterable {
    /// PROVEN: `RevokeIncomplete.notDurable` — the intent item was read, the id was not in it and the
    /// write failed. The only thing denying the device is this process's in-memory `HostControl`
    /// fence, so quitting or crashing Portview RE-ADMITS it. Say so categorically.
    case notDurable
    /// UNKNOWN: `RevokeIncomplete.durabilityUnknown` — the intent item could not be read, so an
    /// earlier attempt's durable intent may or may not still be denying the device. Categorical
    /// "regains access on restart" copy here is factually wrong (an untouched durable `{K}` still
    /// denies K in a fresh process), so the row must hedge instead.
    case unverified
}

/// What a row with an incomplete revoke may honestly claim about its fence surviving a restart.
/// `.unverified` is split by whether the LAST KNOWN durable intent set still lists the device: if it
/// does, the row must not suggest re-admission at all (that would contradict its own pending state —
/// Sol pass 3 N1); if it does not, the row hedges. Neither variant is ever categorical.
enum RevokeDurability: Sendable, Equatable, CaseIterable {
    /// Proven durably fenced (or never in doubt): the plain "revoke incomplete" row.
    case durable
    /// Proven nothing durable was recorded: state the re-admission outright.
    case notDurable
    /// Unknown, and no durable intent is known for this device: hedge ("may … couldn't verify").
    case unverified
    /// Unknown, but the last successful read of the intent item DID list this device: the fence was
    /// last seen durable, so say the check failed — never that access may come back.
    case unverifiedFenceLastSeen
}

/// Why a paired device is currently denied — carrying the PROVENANCE of the denial, which is the
/// whole point (Sol pass 4 F1). `PairingStore.pendingRevocations()` used to hand the app one untagged
/// set unioning durably-recorded revocation intents with this process's `unverifiedIntentFence`; the
/// app then defaulted a fence to the ordinary revoke-incomplete row, whose Retry ran a durable
/// destructive `revoke` with no confirmation and no `LAContext`. The two denials are different facts
/// with different authenticated histories and they get different cases here.
enum DeviceRowStatus: Sendable, Equatable {
    /// Nothing pending: the ordinary row, whose only action is the confirmed + authenticated Revoke.
    case authorized
    /// A revoke was ASKED FOR — an authenticated `revoke` ran — but its durable removal was never
    /// confirmed. Continuing it (Retry) is continuing a decision the owner already authenticated, and
    /// it is still destructive, so it still owes both gates.
    case revokeIncomplete(RevokeDurability)
    /// NOT a revoke. Nobody asked to remove this device: its own `enroll` could not verify that no
    /// revocation intent is pending, so THIS PROCESS denies it (`PairingStore`'s
    /// `unverifiedIntentFence`, design §6d item 8a). The only authenticated decision in its history is
    /// an ADMIT, so the fitting recovery is the authenticated re-admit (a genuine read of the durable
    /// item, which is exactly what lifts the fence) — never a durable revoke nobody requested.
    case enrollmentUnverified

    /// Every status, for exhaustive table-driven tests.
    static let all: [DeviceRowStatus] =
        [.authorized] + RevokeDurability.allCases.map(DeviceRowStatus.revokeIncomplete) + [.enrollmentUnverified]

    /// What this status permits ANY user-facing copy to claim about the device getting its access
    /// back after a Portview restart. Both the row warning and the activity-log line are rendered from
    /// this one value (`DeviceStatusCopy`), which is what makes them structurally incapable of
    /// disagreeing (Sol pass 4 F2).
    var restartClaim: RestartClaim {
        switch self {
        case .authorized: .silent
        case .revokeIncomplete(.durable): .silent
        case .revokeIncomplete(.notDurable): .willReAdmit
        case .revokeIncomplete(.unverified): .mayReAdmit
        // The durable set last listed this device, so its fence was last seen surviving a restart:
        // raising re-admission here would contradict the row's own pending state.
        case .revokeIncomplete(.unverifiedFenceLastSeen): .silent
        // A fence is not a revoke: the device is denied only in this process, and the honest copy is
        // about the unfinished pairing, not about access coming back.
        case .enrollmentUnverified: .silent
        }
    }

    /// The recovery actions this row may offer — the ONE place the surface's routing is decided, and
    /// the reason a fence can no longer reach `retryRevoke`. `MenuBarHostView` builds its buttons from
    /// this list, so the table is load-bearing rather than decorative.
    var recoveryActions: [RecoveryAction] {
        switch self {
        case .authorized: [.revoke]
        case .revokeIncomplete: [.retryRevoke, .cancelRevoke]
        // Revoke stays available (it is the ordinary destructive path, with both its gates); Retry is
        // NOT, because there is no authenticated revoke decision to continue.
        case .enrollmentUnverified: [.finishPairing, .revoke]
        }
    }
}

/// What may be said about a restart. Deliberately a type rather than a `Bool` so the two non-claiming
/// reasons stay distinguishable in the copy that surrounds the (absent) claim.
enum RestartClaim: Sendable, Equatable {
    /// Nothing may be said about a restart.
    case silent
    /// PROVEN: the device gets its access back when Portview restarts.
    case willReAdmit
    /// UNKNOWN: it may get its access back; nothing proves either way.
    case mayReAdmit
}

/// One action a row can offer, and the gates it OWES. Purely descriptive — the confirmation dialog is
/// presented by the view and the `LAContext` evaluation is run by `HostAppModel`; this type cannot
/// perform or bypass either. It exists so "which actions may this row offer, and what must each one
/// clear first" is a testable table instead of scattered `if`s across a `@MainActor` view model.
enum RecoveryAction: Sendable, Hashable, CaseIterable {
    /// Durable `PairingStore.revoke` on a device that is currently fine.
    case revoke
    /// Durable `PairingStore.revoke` re-attempted for a revoke that already started.
    case retryRevoke
    /// Authenticated re-admit of a wedged revoke: discharge the durable intent, lift the lease fence.
    case cancelRevoke
    /// Authenticated re-admit of an enrollment fence: the same discharge, reached from a row that was
    /// never revoked. Separate from `cancelRevoke` so its button and its `LAContext` reason can tell
    /// the truth about what the row actually is.
    case finishPairing

    var title: String {
        switch self {
        case .revoke: "Revoke"
        case .retryRevoke: "Retry"
        case .cancelRevoke: "Cancel"
        case .finishPairing: "Finish pairing"
        }
    }

    /// True iff invoking it runs a durable `PairingStore.revoke` — i.e. it destroys an enrollment.
    var isDestructive: Bool {
        switch self {
        case .revoke, .retryRevoke: true
        case .cancelRevoke, .finishPairing: false
        }
    }

    /// EVERY action here changes an authorization outcome — two remove access, two grant it back — and
    /// a connected authenticated peer can inject a click on the host's screen (han.3 "GLM2"). So all
    /// four require a fresh POSITIVE `LAContext` evaluation; there is no unauthenticated row action.
    var requiresLocalPresence: Bool { true }

    /// Destructive actions additionally require the confirmation dialog (product decision 1) BEFORE
    /// the `LAContext` gate. Retry is destructive, so it carries the dialog too.
    var requiresConfirmation: Bool { isDestructive }

    /// The confirmation dialog's own copy — non-nil for exactly the actions that must pass it. Retry
    /// gets its own wording: the device it is about is ALREADY blocked, so "it will lose access
    /// immediately" would be describing something that already happened.
    var confirmation: (verb: String, message: String)? {
        switch self {
        case .revoke: ("Revoke", "It will lose access immediately.")
        case .retryRevoke: ("Finish revoking", "It is blocked already; this removes its pairing for good.")
        case .cancelRevoke, .finishPairing: nil
        }
    }
}

/// Pure projection of every provenance-bearing input onto ONE status per device. Injectable and free
/// of `@MainActor`, `LAContext` and the keychain, so `HostAppModel` can hold nothing but the inputs
/// and delegate — the row, the activity log and the action routing then cannot drift apart, because
/// there is only one place that decides.
struct DeviceStatusResolver: Sendable, Equatable {
    /// Ids whose durable revoke threw IN THIS PROCESS and whose `RevokeLease` is retained.
    var leaseHeld: Set<String> = []
    /// Ids with a DURABLY RECORDED revocation intent (`PendingRevocations.known(durable:)`).
    var durableIntents: Set<String> = []
    /// Ids denied ONLY by this process's unverified-intent fence
    /// (`PendingRevocations.known(enrollmentFenced:)`) — a failed enrollment, never a revoke.
    var enrollmentFences: Set<String> = []
    /// What the last failed revoke proved about each id's durability.
    var durabilityWarnings: [String: RevokeDurabilityWarning] = [:]

    func status(_ id: String) -> DeviceRowStatus {
        // Revoke provenance FIRST and it is the only thing that can produce a revoke row: a retained
        // lease, a durably recorded intent, or a classified revoke failure all mean an authenticated
        // `revoke` ran. `PairingStore` keeps the two sets disjoint (durable wins), so a device that
        // carries both a recorded intent and a fence lands here, correctly, on the revoke row.
        if leaseHeld.contains(id) || durableIntents.contains(id) || durabilityWarnings[id] != nil {
            return .revokeIncomplete(durability(id))
        }
        if enrollmentFences.contains(id) { return .enrollmentUnverified }
        return .authorized
    }

    /// The absence of a warning defaults to `.durable` — correct ONLY because reaching this function
    /// already required revoke provenance. Applying the same default to a bare enrollment fence is the
    /// laundering `status(_:)` above exists to prevent (Sol pass 4 F1).
    private func durability(_ id: String) -> RevokeDurability {
        switch durabilityWarnings[id] {
        case .none: .durable
        case .notDurable: .notDurable
        case .unverified: durableIntents.contains(id) ? .unverifiedFenceLastSeen : .unverified
        }
    }
}

/// Every user-facing string a device row produces — the row's warning, the short line beside its
/// buttons, and the activity-log entry — rendered from the SAME `DeviceRowStatus`.
///
/// This is the F2 fix. The row already distinguished `.unverified` from `.unverifiedFenceLastSeen`,
/// but the log line was built separately and appended a categorical "MAY regain access if Portview
/// restarts" for BOTH — so in the exact counterexample (an earlier attempt left a durable intent,
/// Retry cannot re-read it, the cached pending set still lists the device) the row said "couldn't
/// re-check" while the log, visible in the main window, simultaneously warned of re-admission. Both
/// strings now take their restart sentence from `status.restartClaim`, so there is no longer a
/// reachable state in which they disagree.
enum DeviceStatusCopy {
    /// The single restart sentence, in the row's terse voice and the log's full-sentence voice. `nil`
    /// = this status may not raise a restart at all, in EITHER surface.
    private static func restartPhrase(_ claim: RestartClaim) -> (row: String, log: String)? {
        switch claim {
        case .silent: nil
        case .willReAdmit: ("regains access if Portview restarts", "it REGAINS ACCESS if Portview restarts")
        case .mayReAdmit: ("MAY regain access if Portview restarts", "it MAY regain access if Portview restarts")
        }
    }

    /// The prominent warning line on the row; `nil` when the status warrants none.
    static func rowWarning(_ status: DeviceRowStatus) -> String? {
        let restart = restartPhrase(status.restartClaim)
        switch status {
        case .authorized, .revokeIncomplete(.durable):
            return nil
        case .revokeIncomplete(.notDurable):
            guard let restart else { return nil }
            return "revoke NOT saved — \(restart.row)"
        case .revokeIncomplete(.unverified):
            guard let restart else { return nil }
            return "couldn't verify the revoke was saved — it \(restart.row)"
        case .revokeIncomplete(.unverifiedFenceLastSeen):
            return "couldn't re-check the saved revoke — the pairing store is unreadable"
        case .enrollmentUnverified:
            return "pairing never finished — blocked until you confirm you're at this Mac"
        }
    }

    /// The short status beside the row's buttons.
    static func rowStatusLine(_ status: DeviceRowStatus) -> String? {
        switch status {
        case .authorized: nil
        case .revokeIncomplete(.durable): "revoke incomplete"
        case .revokeIncomplete(.notDurable): "blocked only while Portview runs"
        case .revokeIncomplete(.unverified), .revokeIncomplete(.unverifiedFenceLastSeen):
            "blocked now — durability unverified"
        case .enrollmentUnverified: "pairing unverified — blocked"
        }
    }

    /// The main window's activity log drops any line at or above this length (`ContentView`'s
    /// `displayedLog` filter, which exists to keep CLI-only multi-line artifacts out of the GUI). A
    /// warning long enough to trip it is a warning the user never sees, so every `logLine` must stay
    /// under it for a realistically long device name — `DeviceStatusCopyTests` pins that.
    static let activityLogCharacterLimit = 160

    /// The activity-log entry for a device that just ENTERED this status; `nil` when the status is not
    /// worth a log line.
    static func logLine(_ status: DeviceRowStatus, deviceName: String) -> String? {
        let restart = restartPhrase(status.restartClaim)
        switch status {
        case .authorized:
            return nil
        case .revokeIncomplete(.durable):
            return "\(deviceName) is now blocked even if Portview restarts, but the revoke still hasn't finished — keep retrying."
        case .revokeIncomplete(.notDurable):
            guard let restart else { return nil }
            return "Couldn't record that revoke — \(deviceName) is blocked now, but \(restart.log). Retry until this clears."
        case .revokeIncomplete(.unverified):
            guard let restart else { return nil }
            return "Couldn't check whether that revoke saved — \(deviceName) is blocked now, but \(restart.log). Retry until this clears."
        case .revokeIncomplete(.unverifiedFenceLastSeen):
            return "Couldn't re-check that revoke — the pairing store is unreadable. \(deviceName) stays blocked; its saved revoke is still on record."
        case .enrollmentUnverified:
            return "\(deviceName) never finished pairing and is blocked here. Confirm you're at this Mac to finish it, or revoke it."
        }
    }
}

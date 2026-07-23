// SPDX-License-Identifier: Apache-2.0
import Foundation
import PortviewTransport

/// Host-LOCAL rollout policy for the mutual-auth streaming gate (spec §4-RESOLVED, decisions.md
/// 2026-07-21 #4). NEVER wire-negotiated: `ProtocolVersion.negotiate` takes the LOWER version, so
/// any "authenticate when version ≥ N" gate is bypassable by advertising v1. The host decides
/// locally; the wire carries only the challenge/response.
public enum MutualAuthPolicy: Equatable, Sendable {
    /// Every streaming connection must prove possession of an enrolled device key (fail-closed).
    case required
    /// Time-bounded migration escape hatch: a client that never answers the challenge is admitted
    /// as a warned legacy session. Auth-capable clients still authenticate. Tightens one-way —
    /// by the expiry, or immediately once ANY device is enrolled (auto-promotion: only
    /// auth-capable clients can have enrolled, so the hatch has served its purpose).
    case legacyBootstrap(expiresAt: Date)

    /// What the gate enforces for one connection, evaluated at connection time.
    public enum Mode: Equatable, Sendable {
        case required
        case bootstrap
    }

    public func effectiveMode(now: Date, enrollment: EnrollmentSnapshot) -> Mode {
        switch self {
        case .required:
            return .required
        case .legacyBootstrap(let expiresAt):
            switch enrollment {
            case .populated:
                // Auto-promotion: a device is enrolled, the migration window has served its
                // purpose (only auth-capable clients can enroll).
                return .required
            case .unreadable:
                // Fail closed: an unverifiable store must NOT reopen bootstrap (Sol han.1 review,
                // CRITICAL). `list().isEmpty` would have read a keychain error as "empty → open."
                return .required
            case .empty:
                return now >= expiresAt ? .required : .bootstrap
            }
        }
    }
}

// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Pure resolution of a completed reachability probe into the user-visible effect (spec §2 steps
/// 3–4): a successful probe becomes a local notification only from the BACKGROUND — a push that
/// arrives while the app is foreground skips the notification and kicks the existing in-app
/// reconnect instead, and a probe that failed always stays silent ("a notification that leads to a
/// dead host is worse than none"). No UIKit here so the routing is unit-testable in the package.
public enum ReWakeRouting {
    public enum Resolution: Equatable, Sendable {
        /// Do nothing: the probe failed, or the foreground app already has a live session to this
        /// same host (already connected — nothing to announce).
        case staySilent
        /// Foreground: enter the saved-Mac reconnect flow directly — never post a notification
        /// over a frontmost app.
        case reconnectInApp
        /// Post the "<Mac> is ready — tap to resume" local notification: from the background (the
        /// entire user-visible deliverable, per the spec's hard iOS constraint), or over a
        /// foreground session to a DIFFERENT Mac (a banner, never a kicked reconnect that would
        /// stomp the session the user is in).
        case postNotification
    }

    public static func resolve(
        probeSucceeded: Bool,
        isForeground: Bool,
        hasLiveSession: Bool,
        liveSessionPinHex: String? = nil,
        beaconPinHex: String? = nil
    ) -> Resolution {
        guard probeSucceeded else { return .staySilent }
        if isForeground {
            guard hasLiveSession else { return .reconnectInApp }
            // A live session suppresses only its OWN host's wake. Another Mac's wake still
            // surfaces — as a notification. When either identity is unknown, stay conservative
            // (the pre-pin behavior): never risk stomping or bannering over the session's host.
            if let liveSessionPinHex, let beaconPinHex, liveSessionPinHex != beaconPinHex {
                return .postNotification
            }
            return .staySilent
        }
        return .postNotification
    }
}

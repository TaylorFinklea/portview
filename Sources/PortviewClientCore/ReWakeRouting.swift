// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Pure resolution of a completed reachability probe into the user-visible effect (spec §2 steps
/// 3–4): a successful probe becomes a local notification only from the BACKGROUND — a push that
/// arrives while the app is foreground skips the notification and kicks the existing in-app
/// reconnect instead, and a probe that failed always stays silent ("a notification that leads to a
/// dead host is worse than none"). No UIKit here so the routing is unit-testable in the package.
public enum ReWakeRouting {
    public enum Resolution: Equatable, Sendable {
        /// Do nothing: the probe failed, or the foreground app already has a live session that a
        /// kicked reconnect would stomp.
        case staySilent
        /// Foreground: enter the saved-Mac reconnect flow directly — never post a notification
        /// over a frontmost app.
        case reconnectInApp
        /// Background: post the "<Mac> is ready — tap to resume" local notification (the entire
        /// user-visible deliverable, per the spec's hard iOS constraint).
        case postNotification
    }

    public static func resolve(probeSucceeded: Bool, isForeground: Bool, hasLiveSession: Bool) -> Resolution {
        guard probeSucceeded else { return .staySilent }
        if isForeground {
            return hasLiveSession ? .staySilent : .reconnectInApp
        }
        return .postNotification
    }
}

// SPDX-License-Identifier: Apache-2.0
import Testing

import PortviewClientCore

/// Foreground-vs-background routing of a completed reachability probe (spec §2 steps 3–4): failed
/// probe → always silent; background success → local notification; foreground success → in-app
/// reconnect, unless a live session would be stomped.
@Suite struct ReWakeRoutingTests {
    @Test func failedProbeStaysSilentRegardlessOfAppState() {
        for isForeground in [true, false] {
            for hasLiveSession in [true, false] {
                let resolution = ReWakeRouting.resolve(
                    probeSucceeded: false, isForeground: isForeground, hasLiveSession: hasLiveSession)
                #expect(resolution == .staySilent)
            }
        }
    }

    @Test func backgroundSuccessPostsTheLocalNotification() {
        // hasLiveSession is a foreground-only concern (a backgrounded session is already dropped),
        // so it must not suppress the background notification either way.
        for hasLiveSession in [true, false] {
            let resolution = ReWakeRouting.resolve(
                probeSucceeded: true, isForeground: false, hasLiveSession: hasLiveSession)
            #expect(resolution == .postNotification)
        }
    }

    @Test func foregroundSuccessKicksInAppReconnectInsteadOfNotifying() {
        let resolution = ReWakeRouting.resolve(probeSucceeded: true, isForeground: true, hasLiveSession: false)
        #expect(resolution == .reconnectInApp)
    }

    @Test func foregroundSuccessWithLiveSessionStaysSilent() {
        let resolution = ReWakeRouting.resolve(probeSucceeded: true, isForeground: true, hasLiveSession: true)
        #expect(resolution == .staySilent)
    }

    // MARK: Per-host live-session suppression (8n1.3 review)

    @Test func liveSessionSuppressesOnlyItsOwnHostsWake() {
        // Streaming Mac A while Mac B reboots and nudges: B's wake must still surface — as a
        // notification banner, never a kicked reconnect that would stomp the A session.
        let sameHost = ReWakeRouting.resolve(
            probeSucceeded: true, isForeground: true, hasLiveSession: true,
            liveSessionPinHex: "aa", beaconPinHex: "aa")
        #expect(sameHost == .staySilent)

        let differentHost = ReWakeRouting.resolve(
            probeSucceeded: true, isForeground: true, hasLiveSession: true,
            liveSessionPinHex: "aa", beaconPinHex: "bb")
        #expect(differentHost == .postNotification)
    }

    @Test func unknownSessionIdentityStaysConservativelySilent() {
        // Mid-connect the session's pin may not be resolved yet: never risk bannering over (or
        // stomping) what may be the same host — the pre-pin behavior is the safe default.
        for (livePin, beaconPin) in [(nil, "bb"), ("aa", nil), (nil, nil)] as [(String?, String?)] {
            let resolution = ReWakeRouting.resolve(
                probeSucceeded: true, isForeground: true, hasLiveSession: true,
                liveSessionPinHex: livePin, beaconPinHex: beaconPin)
            #expect(resolution == .staySilent)
        }
    }

    @Test func pinDistinctionNeverAffectsBackgroundOrNoSessionPaths() {
        let background = ReWakeRouting.resolve(
            probeSucceeded: true, isForeground: false, hasLiveSession: true,
            liveSessionPinHex: "aa", beaconPinHex: "bb")
        #expect(background == .postNotification)

        let noSession = ReWakeRouting.resolve(
            probeSucceeded: true, isForeground: true, hasLiveSession: false,
            liveSessionPinHex: nil, beaconPinHex: "bb")
        #expect(noSession == .reconnectInApp)
    }
}

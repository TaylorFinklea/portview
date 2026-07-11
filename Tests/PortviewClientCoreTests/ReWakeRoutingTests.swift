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
}

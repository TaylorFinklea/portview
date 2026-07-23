// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import Network
@testable import PortviewHostCore

@Suite struct SASAttemptLimiterTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let a = "10.0.0.2"   // per-source keys are remote IPs (port dropped — see sourceKey tests)
    let b = "10.0.0.3"

    @Test func closedByDefault() {
        var l = SASAttemptLimiter()
        #expect(!l.isOpen(now: t0))
        let allowed = l.registerAttempt(source: a, now: t0)
        #expect(allowed == false)  // no attempts allowed while closed
    }

    @Test func opensThenExpiresAfterWindow() {
        var l = SASAttemptLimiter(windowDuration: 120, maxAttempts: 5)
        l.open(now: t0)
        #expect(l.isOpen(now: t0))
        #expect(l.isOpen(now: t0.addingTimeInterval(119)))
        #expect(!l.isOpen(now: t0.addingTimeInterval(120)))   // boundary: exactly at duration → closed
        #expect(!l.isOpen(now: t0.addingTimeInterval(121)))
    }

    @Test func attemptsAllowedUpToCapThenRejected() {
        var l = SASAttemptLimiter(windowDuration: 120, maxAttempts: 3)
        l.open(now: t0)
        let r1 = l.registerAttempt(source: a, now: t0)   // 1
        let r2 = l.registerAttempt(source: a, now: t0)   // 2
        let r3 = l.registerAttempt(source: a, now: t0)   // 3 (== cap, still ok)
        let r4 = l.registerAttempt(source: a, now: t0)   // 4 (exceeds cap)
        let r5 = l.registerAttempt(source: a, now: t0)   // stays rejected
        #expect([r1, r2, r3] == [true, true, true])
        #expect(r4 == false)
        #expect(r5 == false)
    }

    @Test func attemptAfterExpiryIsRejected() {
        var l = SASAttemptLimiter(windowDuration: 120, maxAttempts: 5)
        l.open(now: t0)
        let inWindow = l.registerAttempt(source: a, now: t0)
        let afterExpiry = l.registerAttempt(source: a, now: t0.addingTimeInterval(200))
        #expect(inWindow)
        #expect(afterExpiry == false)
    }

    @Test func reopenResetsAttempts() {
        var l = SASAttemptLimiter(windowDuration: 120, maxAttempts: 2)
        l.open(now: t0)
        _ = l.registerAttempt(source: a, now: t0)
        _ = l.registerAttempt(source: a, now: t0)
        let capped = l.registerAttempt(source: a, now: t0)   // over cap
        l.open(now: t0.addingTimeInterval(300))              // user re-opens
        let afterReopen = l.registerAttempt(source: a, now: t0.addingTimeInterval(300))
        #expect(capped == false)
        #expect(afterReopen)                                 // fresh budget
    }

    @Test func closeStopsAttempts() {
        var l = SASAttemptLimiter(windowDuration: 120, maxAttempts: 5)
        l.open(now: t0)
        let before = l.registerAttempt(source: a, now: t0)
        l.close()
        let openAfterClose = l.isOpen(now: t0)
        let after = l.registerAttempt(source: a, now: t0)
        #expect(before)
        #expect(!openAfterClose)
        #expect(after == false)
    }

    // MARK: - Per-source isolation (a flooder must not deny the legit device)

    @Test func floodedSourceDoesNotCloseWindowForOtherSources() {
        var l = SASAttemptLimiter(windowDuration: 120, maxAttempts: 2, maxTotalAttempts: 20)
        l.open(now: t0)
        for _ in 0..<10 { _ = l.registerAttempt(source: a, now: t0) }  // A floods well past its cap
        let aAfterFlood = l.registerAttempt(source: a, now: t0)
        let bFirst = l.registerAttempt(source: b, now: t0)
        #expect(l.isOpen(now: t0))          // window survives A's flood
        #expect(aAfterFlood == false)       // A stays capped
        #expect(bFirst)                     // B's budget untouched
    }

    @Test func singleGrinderStillCapped() {
        var l = SASAttemptLimiter(windowDuration: 120, maxAttempts: 5)
        l.open(now: t0)
        var allowed = 0
        for _ in 0..<50 where l.registerAttempt(source: a, now: t0) { allowed += 1 }
        #expect(allowed == 5)  // per-source cap is the same hard ceiling a lone grinder always had
    }

    @Test func rejectedFloodDoesNotBurnGlobalBudget() {
        var l = SASAttemptLimiter(windowDuration: 120, maxAttempts: 2, maxTotalAttempts: 4)
        l.open(now: t0)
        for _ in 0..<50 { _ = l.registerAttempt(source: a, now: t0) }  // 48 rejected over-cap attempts
        // A's rejected attempts must not count toward the window total, or the flood DoS is back
        // (just needing maxTotal instead of maxAttempts tries): B still gets its full budget.
        let b1 = l.registerAttempt(source: b, now: t0)
        let b2 = l.registerAttempt(source: b, now: t0)
        #expect(b1)
        #expect(b2)
        #expect(l.isOpen(now: t0))
    }

    // MARK: - Global window budget (source rotation must not yield unbounded guesses)

    @Test func sourceRotationBoundedByGlobalWindowBudget() {
        var l = SASAttemptLimiter(windowDuration: 120, maxAttempts: 5, maxTotalAttempts: 6)
        l.open(now: t0)
        var allowed = 0
        for i in 0..<20 where l.registerAttempt(source: "10.0.0.\(i)", now: t0) { allowed += 1 }
        #expect(allowed == 6)      // rotating sources never exceeds the window-wide ceiling
        #expect(!l.isOpen(now: t0))  // exhausting the ceiling closes the window (hard guess bound)
    }

    @Test func globalExhaustionRejectsEveryLaterSource() {
        var l = SASAttemptLimiter(windowDuration: 120, maxAttempts: 5, maxTotalAttempts: 2)
        l.open(now: t0)
        let first = l.registerAttempt(source: a, now: t0)
        let second = l.registerAttempt(source: b, now: t0)
        _ = l.registerAttempt(source: "10.0.0.4", now: t0)  // trips the ceiling → window closes
        let freshSource = l.registerAttempt(source: "10.0.0.5", now: t0)
        #expect(first)
        #expect(second)
        #expect(freshSource == false)  // fresh source: still shut
    }

    @Test func reopenResetsGlobalBudget() {
        var l = SASAttemptLimiter(windowDuration: 120, maxAttempts: 5, maxTotalAttempts: 2)
        l.open(now: t0)
        _ = l.registerAttempt(source: a, now: t0)
        _ = l.registerAttempt(source: b, now: t0)
        _ = l.registerAttempt(source: "10.0.0.4", now: t0)  // ceiling tripped, window closed
        l.open(now: t0.addingTimeInterval(300))             // user re-opens
        let afterReopen = l.registerAttempt(source: a, now: t0.addingTimeInterval(300))
        #expect(afterReopen)  // fresh budgets
    }

    // MARK: - Source key (remote IP, port dropped — a source port rotates per QUIC dial, so keying
    // on it would hand a flooder a fresh per-source budget on every connection)

    @Test func sourceKeyIgnoresPort() {
        let dial1 = NWEndpoint.hostPort(host: "10.0.0.2", port: 50_001)
        let dial2 = NWEndpoint.hostPort(host: "10.0.0.2", port: 50_002)
        #expect(SASPairingControl.sourceKey(for: dial1) == SASPairingControl.sourceKey(for: dial2))
    }

    @Test func sourceKeyDistinguishesHosts() {
        let deviceA = NWEndpoint.hostPort(host: "10.0.0.2", port: 50_001)
        let deviceB = NWEndpoint.hostPort(host: "10.0.0.3", port: 50_001)
        #expect(SASPairingControl.sourceKey(for: deviceA) != SASPairingControl.sourceKey(for: deviceB))
    }

    @Test func unresolvedEndpointsShareOneBucket() {
        // A path that hasn't resolved yet has no endpoint; all such connections share a single
        // per-source budget rather than each minting a fresh one.
        #expect(SASPairingControl.sourceKey(for: nil) == SASPairingControl.sourceKey(for: nil))
        #expect(SASPairingControl.sourceKey(for: nil)
                != SASPairingControl.sourceKey(for: .hostPort(host: "10.0.0.2", port: 50_001)))
    }

    // MARK: - IPv6 /64 bucketing (one machine self-assigns many addresses inside its on-link /64
    // via SLAAC/privacy addressing — no NAT — so per-address keys would mint a flooder a fresh
    // budget per address; the /64 prefix is the per-machine-network key)

    @Test func sourceKeyBucketsSameIPv6Slash64Together() {
        let addr1 = NWEndpoint.hostPort(host: "fd12:3456:789a:1::42", port: 50_001)
        let addr2 = NWEndpoint.hostPort(host: "fd12:3456:789a:1:d00d:beef:cafe:f00d", port: 50_002)
        #expect(SASPairingControl.sourceKey(for: addr1) == SASPairingControl.sourceKey(for: addr2))
    }

    @Test func sourceKeyDistinguishesIPv6Slash64Prefixes() {
        let netA = NWEndpoint.hostPort(host: "fd12:3456:789a:1::42", port: 50_001)
        let netB = NWEndpoint.hostPort(host: "fd12:3456:789a:2::42", port: 50_001)
        #expect(SASPairingControl.sourceKey(for: netA) != SASPairingControl.sourceKey(for: netB))
    }

    @Test func sameSlash64RotationSharesOnePerSourceBudget() {
        // The attack this closes: a flooder rotating self-assigned addresses within its /64 must
        // exhaust ONE per-source budget, not mint a fresh one per address.
        var l = SASAttemptLimiter(windowDuration: 120, maxAttempts: 2, maxTotalAttempts: 20)
        l.open(now: t0)
        let addr1 = SASPairingControl.sourceKey(
            for: .hostPort(host: "fd12:3456:789a:1::42", port: 50_001))
        let addr2 = SASPairingControl.sourceKey(
            for: .hostPort(host: "fd12:3456:789a:1:aaaa:bbbb:cccc:dddd", port: 50_002))
        _ = l.registerAttempt(source: addr1, now: t0)
        _ = l.registerAttempt(source: addr1, now: t0)           // shared budget hits the cap
        let rotated = l.registerAttempt(source: addr2, now: t0)
        #expect(rotated == false)    // fresh address, same /64 → still capped
        #expect(l.isOpen(now: t0))   // and the over-cap rotation doesn't close the window
    }

    @Test func distinctSlash64PrefixesKeepIsolatedBudgets() {
        var l = SASAttemptLimiter(windowDuration: 120, maxAttempts: 2, maxTotalAttempts: 20)
        l.open(now: t0)
        let netA = SASPairingControl.sourceKey(
            for: .hostPort(host: "fd12:3456:789a:1::42", port: 50_001))
        let netB = SASPairingControl.sourceKey(
            for: .hostPort(host: "fd12:3456:789a:2::42", port: 50_001))
        for _ in 0..<10 { _ = l.registerAttempt(source: netA, now: t0) }  // A's /64 floods past cap
        let bFirst = l.registerAttempt(source: netB, now: t0)
        #expect(bFirst)  // the other /64's budget is untouched
    }

    @Test func slash64RotationStillBoundedByGlobalCeiling() {
        // The window-wide ceiling is unchanged: rotating across many distinct /64s stays bounded.
        var l = SASAttemptLimiter(windowDuration: 120, maxAttempts: 5, maxTotalAttempts: 6)
        l.open(now: t0)
        var allowed = 0
        for i in 0..<20 {
            let key = SASPairingControl.sourceKey(
                for: .hostPort(host: NWEndpoint.Host("fd12:3456:789a:\(String(i, radix: 16))::1"),
                               port: 50_001))
            if l.registerAttempt(source: key, now: t0) { allowed += 1 }
        }
        #expect(allowed == 6)        // rotating /64s never exceeds the window-wide ceiling
        #expect(!l.isOpen(now: t0))  // exhausting the ceiling still closes the window
    }

    @Test func sourceKeyStripsIPv6ScopeIdentifier() {
        // Zone/scope IDs live in `IPv6Address.interface`, not the address bytes; the key is taken
        // from the bare bytes so it deliberately STRIPS them — two addresses differing only in
        // scope must bucket together (varying the zone must not mint budgets).
        let unscoped = NWEndpoint.hostPort(host: "fe80::1", port: 50_001)
        let scoped = NWEndpoint.hostPort(host: "fe80::1%lo0", port: 50_002)  // lo0: on every mac
        #expect(SASPairingControl.sourceKey(for: unscoped) == SASPairingControl.sourceKey(for: scoped))
    }

    @Test func ipv4MappedIPv6KeysAsItsEmbeddedIPv4() {
        // Dual-stack listeners surface v4 peers as ::ffff:a.b.c.d, whose upper 64 bits are all
        // zero. Those key as their embedded IPv4 address — matching the plain-IPv4 key, not
        // collapsing every v4 client into one shared all-zeros /64 bucket.
        let mappedA = NWEndpoint.hostPort(host: "::ffff:10.0.0.2", port: 50_001)
        let mappedB = NWEndpoint.hostPort(host: "::ffff:10.0.0.3", port: 50_001)
        let plainA = NWEndpoint.hostPort(host: "10.0.0.2", port: 50_002)
        #expect(SASPairingControl.sourceKey(for: mappedA) == SASPairingControl.sourceKey(for: plainA))
        #expect(SASPairingControl.sourceKey(for: mappedA) != SASPairingControl.sourceKey(for: mappedB))
    }

    @Test func ipv4BudgetsUnaffectedByBucketing() {
        // IPv4 keys stay per-address: same IP (any port) shares one budget, distinct IPs stay
        // isolated (the shared-NAT caveat is accepted as before).
        var l = SASAttemptLimiter(windowDuration: 120, maxAttempts: 2, maxTotalAttempts: 20)
        l.open(now: t0)
        let a1 = SASPairingControl.sourceKey(for: .hostPort(host: "10.0.0.2", port: 50_001))
        let a2 = SASPairingControl.sourceKey(for: .hostPort(host: "10.0.0.2", port: 50_002))
        let b1 = SASPairingControl.sourceKey(for: .hostPort(host: "10.0.0.3", port: 50_001))
        _ = l.registerAttempt(source: a1, now: t0)
        _ = l.registerAttempt(source: a2, now: t0)          // same IP, new port → shared cap hit
        let aCapped = l.registerAttempt(source: a1, now: t0)
        let bFirst = l.registerAttempt(source: b1, now: t0)
        #expect(aCapped == false)
        #expect(bFirst)
    }

    // MARK: - IPv4 link-local bucketing (169.254.0.0/16 is APIPA — self-assigned when DHCP fails —
    // so many distinct devices on a segment can each mint one, and per-address keying would hand
    // each an independent budget; all such addresses share one bucket instead)

    @Test func sourceKeyBucketsIPv4LinkLocalTogether() {
        let addr1 = NWEndpoint.hostPort(host: "169.254.1.2", port: 50_001)
        let addr2 = NWEndpoint.hostPort(host: "169.254.9.9", port: 50_002)
        #expect(SASPairingControl.sourceKey(for: addr1) == SASPairingControl.sourceKey(for: addr2))
    }

    @Test func sourceKeyLeavesRoutableIPv4Unchanged() {
        let linkLocal = NWEndpoint.hostPort(host: "169.254.1.2", port: 50_001)
        let routable = NWEndpoint.hostPort(host: "10.0.0.2", port: 50_002)
        #expect(SASPairingControl.sourceKey(for: linkLocal) != SASPairingControl.sourceKey(for: routable))
        #expect(SASPairingControl.sourceKey(for: routable) == "10.0.0.2")
    }

    // MARK: - IPv4-mapped IPv6 link-local (::ffff:169.254.x.x must bucket the same as plain
    // 169.254.x.x — the embedded-v4 extraction in the .ipv6 branch must apply the same link-local
    // check, not just the plain .ipv4 branch, or a dual-stack listener's mapped view of an APIPA
    // peer bypasses the shared bucket)

    @Test func sourceKeyBucketsMappedIPv4LinkLocalWithPlainLinkLocal() {
        let mappedLinkLocal = NWEndpoint.hostPort(host: "::ffff:169.254.1.2", port: 50_001)
        let plainLinkLocal = NWEndpoint.hostPort(host: "169.254.9.9", port: 50_002)
        #expect(SASPairingControl.sourceKey(for: mappedLinkLocal) == SASPairingControl.sourceKey(for: plainLinkLocal))
    }

    @Test func sourceKeyMappedRoutableIPv4StaysUnchanged() {
        let mappedRoutable = NWEndpoint.hostPort(host: "::ffff:10.0.0.2", port: 50_001)
        #expect(SASPairingControl.sourceKey(for: mappedRoutable) == "10.0.0.2")
    }
}

/// Claims the HUD's single code-display slot as an owner-token LEASE so a second concurrent SAS
/// preamble can't overwrite the code the user is looking at (must-fix 6): only one connection may
/// hold the lease at a time, a stale/non-owner token's release is a no-op (a losing/late connection
/// can't evict the real owner), and opening a fresh pairing window force-releases any lease left
/// over from a previous window — the STRIPPED holder must observe that loss via
/// `holdsCodeDisplay(token:)` rather than keep believing it still owns the slot.
@Suite struct SASCodeDisplayClaimTests {
    @Test func firstClaimSucceedsSecondFailsUntilRelease() async throws {
        let sas = SASPairingControl()
        let first = try #require(await sas.claimCodeDisplay(source: "10.0.0.2"))
        let second = await sas.claimCodeDisplay(source: "10.0.0.3")
        #expect(second == nil)
        await sas.releaseCodeDisplay(token: first)
        let afterRelease = await sas.claimCodeDisplay(source: "10.0.0.3")
        #expect(afterRelease != nil)
    }

    @Test func releaseByStaleTokenIsANoOp() async throws {
        let sas = SASPairingControl()
        let owner = try #require(await sas.claimCodeDisplay(source: "10.0.0.2"))
        await sas.releaseCodeDisplay(token: owner + 1)   // not the current owner token — no-op
        let stillHeld = await sas.claimCodeDisplay(source: "10.0.0.3")
        #expect(stillHeld == nil)
        #expect(await sas.holdsCodeDisplay(token: owner))   // original lease is untouched
    }

    @Test func openWindowForceReleasesStaleClaimAndStrippedHolderObservesIt() async throws {
        // The exact must-fix-6 driving scenario: claim → openWindow() strips it → the OLD holder
        // must see it lost the lease (not keep emitting as if it still owned the slot), and a new
        // claim must succeed in its place.
        let sas = SASPairingControl()
        let oldToken = try #require(await sas.claimCodeDisplay(source: "10.0.0.2"))
        await sas.openWindow()
        #expect(await sas.holdsCodeDisplay(token: oldToken) == false)
        let newToken = await sas.claimCodeDisplay(source: "10.0.0.3")
        #expect(newToken != nil)
    }

    @Test func tokensAreMonotonicNotDerivedFromSource() async throws {
        // Tokens come from the actor's own counter, never from `source` — link-local/APIPA and
        // IPv6 /64 bucketing mean distinct connections can share one source key, so a
        // source-derived token could collide across them and let a stripped holder mistake itself
        // for the new owner.
        let sas = SASPairingControl()
        let first = try #require(await sas.claimCodeDisplay(source: "169.254.0.0/16"))
        await sas.releaseCodeDisplay(token: first)
        let second = try #require(await sas.claimCodeDisplay(source: "169.254.0.0/16"))
        #expect(first != second)
    }

    @Test func holdsCodeDisplayIsFalseForANonOwnerToken() async throws {
        let sas = SASPairingControl()
        let owner = try #require(await sas.claimCodeDisplay(source: "10.0.0.2"))
        #expect(await sas.holdsCodeDisplay(token: owner + 1) == false)
    }
}

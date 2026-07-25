// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation
import Network
import Testing

@testable import PortviewHostCore
@testable import PortviewTransport
import PortviewProtocol

/// End-to-end loopback exercise of the auth gate WIRED into the real `serveSession`: a real client
/// over a real QUIC connection. Complements AuthGateTests (which prove the gate's decision table
/// seam-driven): these prove the serveSession integration — a rejected peer is closed with NO
/// scaffolding built, an authenticated peer proceeds past the gate, and a non-hello first frame
/// closes before a challenge is even issued.
@Suite(.timeLimit(.minutes(1))) struct AuthGateSessionTests {
    private final class MemoryPairingStore: PairingRecordStore, @unchecked Sendable {
        private let lock = NSLock()
        private var blob: Data?
        func read() throws -> Data? { lock.lock(); defer { lock.unlock() }; return blob }
        func write(_ data: Data) throws { lock.lock(); defer { lock.unlock() }; blob = data }
    }

    /// A `PairingRecordStore` whose `write` always throws — drives the ceremony's fail-closed
    /// `enroll` path (Task 6): an un-persistable enrollment must never let the connection proceed
    /// as authenticated.
    private final class ThrowingWritePairingStore: PairingRecordStore, @unchecked Sendable {
        private enum StoreError: Error { case injectedWriteFailure }
        func read() throws -> Data? { nil }
        func write(_ data: Data) throws { throw StoreError.injectedWriteFailure }
    }

    private enum TestHarnessError: Error { case noChallenge, noAcceptedConnection }

    private actor Probe {
        private(set) var outcomes: [HostRunner.AuthGateOutcome] = []
        private(set) var scaffoldingBuilds = 0
        func record(_ outcome: HostRunner.AuthGateOutcome) { outcomes.append(outcome) }
        func recordScaffolding() { scaffoldingBuilds += 1 }
    }

    /// Collects every `HostRunnerEvent` a session emits, for the hygiene assertion that the
    /// unknown-key path never leaks the raw public key via an emitted event.
    private actor EventCollector {
        private(set) var events: [HostRunnerEvent] = []
        func record(_ event: HostRunnerEvent) { events.append(event) }
    }

    /// Serve every accepted connection with the REAL serveSession (empty display registry — the
    /// gate must resolve before any display is needed), recording gate outcomes + scaffolding.
    /// `control`/`sas`/`enrollment` default nil (the 4 pre-Task-6 tests' pass-through shape); the
    /// enrollment-ceremony tests supply all three.
    private func runHost(_ listener: PortviewListener, hostCert: [UInt8],
                         policy: MutualAuthPolicy, pairings: PairingStore,
                         probe: Probe,
                         control: HostControl? = nil,
                         sas: SASPairingControl? = nil,
                         enrollment: EnrollmentAuthority? = nil,
                         emit: @escaping @Sendable (HostRunnerEvent) -> Void = { _ in }) -> Task<Void, Never> {
        Task {
            await withTaskGroup(of: Void.self) { group in
                for await conn in listener.connections {
                    group.addTask {
                        await HostRunner.serveSession(
                            conn, registry: DisplayRegistry([]), hostCertSHA256: hostCert,
                            authPolicy: policy, pairings: pairings, emit: emit,
                            control: control, sas: sas, enrollment: enrollment,
                            onAuthGateOutcome: { o in Task { await probe.record(o) } },
                            didBuildScaffolding: { Task { await probe.recordScaffolding() } })
                    }
                }
            }
        }
    }

    private func hello(deviceName: String = "t") -> AnyMessage {
        .clientHello(ClientHello(protocolVersion: 1, deviceID: "t", deviceName: deviceName, codecs: [.hevc]))
    }

    /// Drives one client connection through ClientHello → ServerChallenge → ClientAuth for `key`,
    /// returning the still-open connection. `deviceName` is the WIRE (pre-sanitize) value, so tests
    /// can exercise the sanitize-once path end to end.
    private func dialAndAuthenticate(
        port: NWEndpoint.Port, key: Curve25519.Signing.PrivateKey, deviceName: String
    ) async throws -> PortviewConnection {
        let (conn, captured) = try await PortviewConnection.connectCapturingCert(
            to: .hostPort(host: "127.0.0.1", port: port))
        try await conn.send(hello(deviceName: deviceName))
        var it = conn.inbound.makeAsyncIterator()
        guard case .serverChallenge(let challenge)? = await it.next() else {
            throw TestHarnessError.noChallenge
        }
        let signature = try ClientAuthCrypto.sign(
            privateKey: key, nonce: challenge.nonce, hostCertSHA256: [UInt8](captured))
        try await conn.send(.clientAuth(ClientAuth(
            publicKey: Array(key.publicKey.rawRepresentation), signature: signature)))
        return conn
    }

    /// One live loopback connection on a THROWAWAY listener, purely so a test can pre-register it
    /// with `HostControl` as an existing "legacy" session (mirrors `HostControlEvictionTests`)
    /// without it being swallowed by `runHost`'s own connection-consuming loop.
    private func standaloneConnection() async throws -> (listener: PortviewListener, connection: PortviewConnection) {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let listener = try PortviewListener(quicIdentity: identity)
        let port = try await listener.start()
        async let client = PortviewConnection.connectCapturingCert(to: .hostPort(host: "127.0.0.1", port: port))
        var it = listener.connections.makeAsyncIterator()
        guard let accepted = await it.next() else { throw TestHarnessError.noAcceptedConnection }
        // Unlike `dialAndAuthenticate`'s returned connection, the client end here is never used by
        // the caller (only the host-side `accepted` is registered) — close it explicitly instead of
        // letting it drop implicitly (mirrors `HostControlEvictionTests.twoHostConnections`, which
        // deliberately keeps its client ends alive/accounted-for through registration).
        let (clientConnection, _) = try await client
        clientConnection.close()
        return (listener, accepted)
    }

    private func awaitOutcome(_ probe: Probe, at index: Int = 0) async -> HostRunner.AuthGateOutcome? {
        for _ in 0..<500 {
            let outcomes = await probe.outcomes
            if outcomes.count > index { return outcomes[index] }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    /// Polls `events` for the FIRST `.enrollmentRequest`, returning its fields once observed.
    private func awaitFirstEnrollmentRequest(_ events: EventCollector)
        async -> (attemptID: UUID, fingerprint: String, claimedName: String, expiresAt: Date)? {
        for _ in 0..<500 {
            for event in await events.events {
                if case .enrollmentRequest(let attemptID, let fingerprint, let claimedName, let expiresAt) = event {
                    return (attemptID, fingerprint, claimedName, expiresAt)
                }
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    /// Polls `events` for `.enrollmentResolved(attemptID, _)`, returning its `approved` value once
    /// observed. Because `runEnrollmentCeremony` emits this only AFTER `enroll`/`evictLegacyAdmitted`
    /// complete (on the approve path), observing it here is a safe ordering barrier for asserting
    /// those downstream effects without racing the ceremony's own async work.
    private func awaitEnrollmentResolved(_ events: EventCollector, attemptID: UUID) async -> Bool? {
        for _ in 0..<500 {
            for event in await events.events {
                if case .enrollmentResolved(let id, let approved) = event, id == attemptID { return approved }
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    /// Scripted approver/denier (Task 6 brief): polls `events` for the first `.enrollmentRequest`,
    /// then resolves that exact attempt.
    private func scriptedResolution(
        _ events: EventCollector, _ authority: EnrollmentAuthority, approve: Bool
    ) -> Task<Void, Never> {
        Task {
            guard let request = await awaitFirstEnrollmentRequest(events) else { return }
            if approve { await authority.approve(request.attemptID) } else { await authority.deny(request.attemptID) }
        }
    }

    @Test func unauthorizedClientAuthClosesWithNoScaffolding() async throws {
        // The bead's named check: a valid-signature auth from an UN-ENROLLED key is rejected and
        // the connection closes with NO scaffolding built.
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let hostCert = [UInt8](try identity.certificateSHA256())
        let listener = try PortviewListener(quicIdentity: identity)
        let port = try await listener.start()
        let pairings = PairingStore(store: MemoryPairingStore())  // nobody enrolled
        let probe = Probe()
        let host = runHost(listener, hostCert: hostCert, policy: .required, pairings: pairings, probe: probe)
        defer { host.cancel(); listener.cancel() }

        let (conn, captured) = try await PortviewConnection.connectCapturingCert(
            to: .hostPort(host: "127.0.0.1", port: port))
        defer { conn.close() }
        try await conn.send(hello())

        var it = conn.inbound.makeAsyncIterator()
        guard case .serverChallenge(let challenge)? = await it.next() else {
            Issue.record("expected ServerChallenge after ClientHello"); return
        }
        let key = Curve25519.Signing.PrivateKey()
        let signature = try ClientAuthCrypto.sign(
            privateKey: key, nonce: challenge.nonce, hostCertSHA256: [UInt8](captured))
        try await conn.send(.clientAuth(ClientAuth(
            publicKey: Array(key.publicKey.rawRepresentation), signature: signature)))

        // The host closes: the client's inbound ends with no ServerHello.
        while let message = await it.next() {
            if case .serverHello = message { Issue.record("rejected peer must never see ServerHello") }
        }
        #expect(await awaitOutcome(probe) == .unknownKey(publicKey: Array(key.publicKey.rawRepresentation)))
        #expect(await probe.scaffoldingBuilds == 0)
    }

    @Test func unknownKeyPathNeverLeaksPubkeyInEmittedEvents() async throws {
        // Hygiene (design v2 M3): the unknown-key path must never leak the raw public key via any
        // emitted `HostRunnerEvent`. Only the `KeyFingerprint` is loggable, and that goes to
        // `os.Logger`, never `emit`. Wired through the FULL ceremony (scripted DENY) so this test
        // actually produces `.enrollmentRequest` + `.enrollmentResolved` events to scan — without a
        // ceremony, the gate closes with zero events and the scan below iterates nothing.
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let hostCert = [UInt8](try identity.certificateSHA256())
        let listener = try PortviewListener(quicIdentity: identity)
        let port = try await listener.start()
        let pairings = PairingStore(store: MemoryPairingStore())  // nobody enrolled
        let probe = Probe()
        let events = EventCollector()
        let sas = SASPairingControl()
        await sas.openWindow()
        let enrollment = EnrollmentAuthority(deadline: .milliseconds(500))
        let control = HostControl(keepAwake: KeepAwake(backend: NoopKeepAwakeBackend()))
        let host = runHost(listener, hostCert: hostCert, policy: .required, pairings: pairings,
                           probe: probe, control: control, sas: sas, enrollment: enrollment,
                           emit: { event in Task { await events.record(event) } })
        defer { host.cancel(); listener.cancel() }

        let denier = scriptedResolution(events, enrollment, approve: false)
        defer { denier.cancel() }

        let key = Curve25519.Signing.PrivateKey()
        let conn = try await dialAndAuthenticate(port: port, key: key, deviceName: "Phone")
        defer { conn.close() }
        var it = conn.inbound.makeAsyncIterator()
        while let message = await it.next() {
            if case .serverHello = message { Issue.record("rejected peer must never see ServerHello") }
        }
        #expect(await awaitOutcome(probe) == .unknownKey(publicKey: Array(key.publicKey.rawRepresentation)))

        guard let request = await awaitFirstEnrollmentRequest(events) else {
            Issue.record("expected an .enrollmentRequest event — the scan below would be vacuous without it")
            return
        }
        guard let approved = await awaitEnrollmentResolved(events, attemptID: request.attemptID) else {
            Issue.record("expected an .enrollmentResolved event"); return
        }
        #expect(approved == false)

        let recordedEvents = await events.events
        // (a) Structural non-vacuousness: at least one enrollment event was actually collected.
        #expect(recordedEvents.contains { if case .enrollmentRequest = $0 { return true }; return false })

        // (b) Hygiene: no collected event — across the whole ceremony, not just the request — ever
        // surfaces the raw public key.
        let pubkeyHex = key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        for event in recordedEvents {
            #expect(!String(describing: event).lowercased().contains(pubkeyHex))
        }
    }

    @Test func enrolledClientAuthenticatesPastTheGate() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let hostCert = [UInt8](try identity.certificateSHA256())
        let listener = try PortviewListener(quicIdentity: identity)
        let port = try await listener.start()
        let key = Curve25519.Signing.PrivateKey()
        let pairings = PairingStore(store: MemoryPairingStore())
        try await pairings.enroll(publicKey: key.publicKey.rawRepresentation, deviceName: "phone")
        let expectedID = PairingStore.deviceID(forPublicKey: key.publicKey.rawRepresentation)
        let probe = Probe()
        let host = runHost(listener, hostCert: hostCert, policy: .required, pairings: pairings, probe: probe)
        defer { host.cancel(); listener.cancel() }

        let (conn, captured) = try await PortviewConnection.connectCapturingCert(
            to: .hostPort(host: "127.0.0.1", port: port))
        defer { conn.close() }
        try await conn.send(hello())

        var it = conn.inbound.makeAsyncIterator()
        guard case .serverChallenge(let challenge)? = await it.next() else {
            Issue.record("expected ServerChallenge after ClientHello"); return
        }
        let signature = try ClientAuthCrypto.sign(
            privateKey: key, nonce: challenge.nonce, hostCertSHA256: [UInt8](captured))
        try await conn.send(.clientAuth(ClientAuth(
            publicKey: Array(key.publicKey.rawRepresentation), signature: signature)))

        // Gate wiring proof: the outcome is authenticated with the enrolled id. (The empty test
        // registry then ends the session at the display guard — scaffolding is display-gated.)
        #expect(await awaitOutcome(probe) == .authenticated(deviceID: expectedID))
    }

    @Test func nonHelloFirstFrameClosesWithoutAChallenge() async throws {
        // Spec §4-RESOLVED: the first frame must be exactly SASClientCommit or ClientHello;
        // anything else closes — before a challenge, before the gate, before anything.
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let hostCert = [UInt8](try identity.certificateSHA256())
        let listener = try PortviewListener(quicIdentity: identity)
        let port = try await listener.start()
        let pairings = PairingStore(store: MemoryPairingStore())
        let probe = Probe()
        let host = runHost(listener, hostCert: hostCert, policy: .required, pairings: pairings, probe: probe)
        defer { host.cancel(); listener.cancel() }

        let (conn, _) = try await PortviewConnection.connectCapturingCert(
            to: .hostPort(host: "127.0.0.1", port: port))
        defer { conn.close() }
        try await conn.send(.ping(Ping(sendMicros: 1)))

        var it = conn.inbound.makeAsyncIterator()
        while let message = await it.next() {
            if case .serverChallenge = message { Issue.record("no challenge for a role-violating peer") }
        }
        #expect(await probe.outcomes.isEmpty)  // the gate never ran
        #expect(await probe.scaffoldingBuilds == 0)
    }

    // MARK: - Task 6: enrollment ceremony wired into serveSession

    @Test func ceremonyApproveEnrollsEvictsAndAuthenticates() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let hostCert = [UInt8](try identity.certificateSHA256())
        let listener = try PortviewListener(quicIdentity: identity)
        let port = try await listener.start()
        let pairings = PairingStore(store: MemoryPairingStore())
        let probe = Probe()
        let events = EventCollector()
        let sas = SASPairingControl()
        await sas.openWindow()
        let enrollment = EnrollmentAuthority(deadline: .milliseconds(500))
        let control = HostControl(keepAwake: KeepAwake(backend: NoopKeepAwakeBackend()))

        // Pre-register a legacy (bootstrap-admitted) session directly on `control`, mirroring
        // HostControlEvictionTests — this is the session the ceremony's eager evict must remove.
        let (legacyListener, legacyConnection) = try await standaloneConnection()
        defer { legacyListener.cancel() }
        control.register("legacy", legacyConnection,
                         outbound: OutboundLane(connection: legacyConnection, capability: SessionCapability()),
                         authClass: .legacyAdmitted,
                         ticket: AdmissionTicket(keyID: nil, generation: 0), capability: SessionCapability())
        #expect(control.activeSessionIDs() == ["legacy"])

        let host = runHost(listener, hostCert: hostCert, policy: .required, pairings: pairings,
                           probe: probe, control: control, sas: sas, enrollment: enrollment,
                           emit: { event in Task { await events.record(event) } })
        defer { host.cancel(); listener.cancel() }

        let approver = scriptedResolution(events, enrollment, approve: true)
        defer { approver.cancel() }

        let key = Curve25519.Signing.PrivateKey()
        // The claimed device name carries a bidi char (U+200E) the sanitizer must strip.
        let rawName = "Att\u{200E}acker Phone"
        let conn = try await dialAndAuthenticate(port: port, key: key, deviceName: rawName)
        defer { conn.close() }

        // DisplayRegistry is empty, so even the ceremony's SUCCESSFUL connection closes at the
        // display guard right after — no ServerHello. The ceremony's outcomes/events (not
        // streaming) are what's under test here, matching the rest of this file's loopback shape.
        var it = conn.inbound.makeAsyncIterator()
        while let message = await it.next() {
            if case .serverHello = message { Issue.record("empty-registry session must not reach ServerHello") }
        }

        let expectedID = PairingStore.deviceID(forPublicKey: key.publicKey.rawRepresentation)
        #expect(await awaitOutcome(probe) == .unknownKey(publicKey: Array(key.publicKey.rawRepresentation)))

        guard let request = await awaitFirstEnrollmentRequest(events) else {
            Issue.record("expected an .enrollmentRequest event"); return
        }
        #expect(request.claimedName == DeviceNameSanitizer.sanitize(rawName))
        #expect(request.fingerprint == KeyFingerprint.short(forPublicKey: key.publicKey.rawRepresentation))

        guard let approved = await awaitEnrollmentResolved(events, attemptID: request.attemptID) else {
            Issue.record("expected an .enrollmentResolved event"); return
        }
        #expect(approved == true)

        // Safe to assert now: `.enrollmentResolved(approved: true)` is emitted only AFTER `enroll`
        // and `evictLegacyAdmitted` complete.
        #expect(await pairings.isAuthorized(id: expectedID) == true)
        #expect(control.activeSessionIDs().isEmpty)  // the pre-registered legacy session was evicted

        // Literal proof of "authenticates": a FRESH connection with the SAME key now clears the
        // gate outright as `.authenticated`, since the enrollment persisted.
        let secondConn = try await dialAndAuthenticate(port: port, key: key, deviceName: "ignored")
        defer { secondConn.close() }
        #expect(await awaitOutcome(probe, at: 1) == .authenticated(deviceID: expectedID))
    }

    @Test func ceremonyDenyClosesSilentlyAndBlocksSource() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let hostCert = [UInt8](try identity.certificateSHA256())
        let listener = try PortviewListener(quicIdentity: identity)
        let port = try await listener.start()
        let pairings = PairingStore(store: MemoryPairingStore())
        let probe = Probe()
        let events = EventCollector()
        let sas = SASPairingControl()
        await sas.openWindow()
        let enrollment = EnrollmentAuthority(deadline: .milliseconds(500))
        let control = HostControl(keepAwake: KeepAwake(backend: NoopKeepAwakeBackend()))

        let host = runHost(listener, hostCert: hostCert, policy: .required, pairings: pairings,
                           probe: probe, control: control, sas: sas, enrollment: enrollment,
                           emit: { event in Task { await events.record(event) } })
        defer { host.cancel(); listener.cancel() }

        let denier = scriptedResolution(events, enrollment, approve: false)
        defer { denier.cancel() }

        let key = Curve25519.Signing.PrivateKey()
        let conn = try await dialAndAuthenticate(port: port, key: key, deviceName: "Denied Phone")
        defer { conn.close() }
        var it = conn.inbound.makeAsyncIterator()
        while let message = await it.next() {
            if case .serverHello = message { Issue.record("a denied peer must never see ServerHello") }
        }

        let expectedID = PairingStore.deviceID(forPublicKey: key.publicKey.rawRepresentation)
        guard let request = await awaitFirstEnrollmentRequest(events) else {
            Issue.record("expected an .enrollmentRequest event"); return
        }
        guard let approved = await awaitEnrollmentResolved(events, attemptID: request.attemptID) else {
            Issue.record("expected an .enrollmentResolved event"); return
        }
        #expect(approved == false)
        #expect(await pairings.isAuthorized(id: expectedID) == false)

        // A second, immediate attempt from the SAME source (127.0.0.1) gets no ceremony at all —
        // the deny blocked the source for the remainder of the window (must-fix 5).
        let secondConn = try await dialAndAuthenticate(port: port, key: key, deviceName: "Denied Phone Again")
        defer { secondConn.close() }
        var it2 = secondConn.inbound.makeAsyncIterator()
        while let message = await it2.next() {
            if case .serverHello = message { Issue.record("a blocked source must never authenticate") }
        }
        #expect(await awaitOutcome(probe, at: 1) == .unknownKey(publicKey: Array(key.publicKey.rawRepresentation)))
        let recordedEvents = await events.events
        let requestEventCount = recordedEvents.filter {
            if case .enrollmentRequest = $0 { return true }; return false
        }.count
        #expect(requestEventCount == 1)  // no second .enrollmentRequest — the source was blocked
    }

    @Test func ceremonyEnrollThrowFailsClosed() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let hostCert = [UInt8](try identity.certificateSHA256())
        let listener = try PortviewListener(quicIdentity: identity)
        let port = try await listener.start()
        let pairings = PairingStore(store: ThrowingWritePairingStore())
        let probe = Probe()
        let events = EventCollector()
        let sas = SASPairingControl()
        await sas.openWindow()
        let enrollment = EnrollmentAuthority(deadline: .milliseconds(500))
        let control = HostControl(keepAwake: KeepAwake(backend: NoopKeepAwakeBackend()))

        let host = runHost(listener, hostCert: hostCert, policy: .required, pairings: pairings,
                           probe: probe, control: control, sas: sas, enrollment: enrollment,
                           emit: { event in Task { await events.record(event) } })
        defer { host.cancel(); listener.cancel() }

        let approver = scriptedResolution(events, enrollment, approve: true)
        defer { approver.cancel() }

        let key = Curve25519.Signing.PrivateKey()
        let conn = try await dialAndAuthenticate(port: port, key: key, deviceName: "Phone")
        defer { conn.close() }
        var it = conn.inbound.makeAsyncIterator()
        while let message = await it.next() {
            if case .serverHello = message { Issue.record("an enroll-failure must never see ServerHello") }
        }

        let expectedID = PairingStore.deviceID(forPublicKey: key.publicKey.rawRepresentation)
        guard let request = await awaitFirstEnrollmentRequest(events) else {
            Issue.record("expected an .enrollmentRequest event"); return
        }
        guard let approved = await awaitEnrollmentResolved(events, attemptID: request.attemptID) else {
            Issue.record("expected an .enrollmentResolved event"); return
        }
        #expect(approved == false)
        #expect(await pairings.isAuthorized(id: expectedID) == false)
        #expect(await probe.scaffoldingBuilds == 0)
    }

    @Test func noAuthorityOrClosedWindowClosesAsToday() async throws {
        // Scenario A: no `enrollment` authority wired in at all (the pre-Task-6 shape).
        do {
            let identity = try TLSIdentity.makeEphemeralSelfSigned()
            let hostCert = [UInt8](try identity.certificateSHA256())
            let listener = try PortviewListener(quicIdentity: identity)
            let port = try await listener.start()
            let pairings = PairingStore(store: MemoryPairingStore())
            let probe = Probe()
            let events = EventCollector()
            let host = runHost(listener, hostCert: hostCert, policy: .required, pairings: pairings,
                               probe: probe, emit: { event in Task { await events.record(event) } })
            defer { host.cancel(); listener.cancel() }

            let key = Curve25519.Signing.PrivateKey()
            let conn = try await dialAndAuthenticate(port: port, key: key, deviceName: "Phone")
            defer { conn.close() }
            var it = conn.inbound.makeAsyncIterator()
            while let message = await it.next() {
                if case .serverHello = message { Issue.record("no authority; must close, no ceremony") }
            }
            #expect(await awaitOutcome(probe) == .unknownKey(publicKey: Array(key.publicKey.rawRepresentation)))
            #expect(await events.events.isEmpty)
        }

        // Scenario B: `enrollment` + `control` ARE wired, but the SAS window was never opened.
        do {
            let identity = try TLSIdentity.makeEphemeralSelfSigned()
            let hostCert = [UInt8](try identity.certificateSHA256())
            let listener = try PortviewListener(quicIdentity: identity)
            let port = try await listener.start()
            let pairings = PairingStore(store: MemoryPairingStore())
            let probe = Probe()
            let events = EventCollector()
            let enrollment = EnrollmentAuthority()
            let sas = SASPairingControl()  // never opened
            let control = HostControl(keepAwake: KeepAwake(backend: NoopKeepAwakeBackend()))
            let host = runHost(listener, hostCert: hostCert, policy: .required, pairings: pairings,
                               probe: probe, control: control, sas: sas, enrollment: enrollment,
                               emit: { event in Task { await events.record(event) } })
            defer { host.cancel(); listener.cancel() }

            let key = Curve25519.Signing.PrivateKey()
            let conn = try await dialAndAuthenticate(port: port, key: key, deviceName: "Phone")
            defer { conn.close() }
            var it = conn.inbound.makeAsyncIterator()
            while let message = await it.next() {
                if case .serverHello = message { Issue.record("closed SAS window; must close, no ceremony") }
            }
            #expect(await awaitOutcome(probe) == .unknownKey(publicKey: Array(key.publicKey.rawRepresentation)))
            #expect(await events.events.isEmpty)
        }
    }

    @Test func ceremonyWorksUnderRequiredMode() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let hostCert = [UInt8](try identity.certificateSHA256())
        let listener = try PortviewListener(quicIdentity: identity)
        let port = try await listener.start()
        let pairings = PairingStore(store: MemoryPairingStore())

        // Device A enrolled BEFORE this connection — auto-promotes a `.legacyBootstrap` policy to
        // its `.required` effective mode (PairingStore.enrollmentSnapshot() == .populated).
        let keyA = Curve25519.Signing.PrivateKey()
        try await pairings.enroll(publicKey: keyA.publicKey.rawRepresentation, deviceName: "Device A")

        let probe = Probe()
        let events = EventCollector()
        let sas = SASPairingControl()
        await sas.openWindow()
        let enrollment = EnrollmentAuthority(deadline: .milliseconds(500))
        let control = HostControl(keepAwake: KeepAwake(backend: NoopKeepAwakeBackend()))
        // `.legacyBootstrap` with a far-future expiry: only the auto-promotion (device A already
        // enrolled) should force `.required` here — proving the ceremony still runs for a NEW
        // device once the policy has promoted, rather than the ceremony being bootstrap-only.
        let policy = MutualAuthPolicy.legacyBootstrap(expiresAt: Date().addingTimeInterval(3600))

        let host = runHost(listener, hostCert: hostCert, policy: policy, pairings: pairings,
                           probe: probe, control: control, sas: sas, enrollment: enrollment,
                           emit: { event in Task { await events.record(event) } })
        defer { host.cancel(); listener.cancel() }

        let approver = scriptedResolution(events, enrollment, approve: true)
        defer { approver.cancel() }

        let keyB = Curve25519.Signing.PrivateKey()
        let conn = try await dialAndAuthenticate(port: port, key: keyB, deviceName: "Device B")
        defer { conn.close() }
        var it = conn.inbound.makeAsyncIterator()
        while let message = await it.next() {
            if case .serverHello = message { Issue.record("empty registry; must not reach ServerHello") }
        }

        let expectedB = PairingStore.deviceID(forPublicKey: keyB.publicKey.rawRepresentation)
        #expect(await awaitOutcome(probe) == .unknownKey(publicKey: Array(keyB.publicKey.rawRepresentation)))
        guard let request = await awaitFirstEnrollmentRequest(events) else {
            Issue.record("expected an .enrollmentRequest event"); return
        }
        guard let approved = await awaitEnrollmentResolved(events, attemptID: request.attemptID) else {
            Issue.record("expected an .enrollmentResolved event"); return
        }
        #expect(approved == true)
        #expect(await pairings.isAuthorized(id: expectedB) == true)
    }
}

/// A keep-awake backend that does nothing (tests must not touch the live IOPM assertion surface —
/// see the `test-live-side-effects` memory).
private final class NoopKeepAwakeBackend: KeepAwakeBackend, @unchecked Sendable {
    func beginPreventingSleep() {}
    func endPreventingSleep() {}
    func declareUserActivity() {}
}

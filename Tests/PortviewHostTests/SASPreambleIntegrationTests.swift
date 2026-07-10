import Testing
import Foundation
import Network
@testable import PortviewHostCore
import PortviewTransport
import PortviewProtocol

/// End-to-end loopback exercise of the host SAS preamble handler (`serveSASPreamble`): a real client
/// runs the commit→reveal→confirm exchange over a real QUIC connection against the real host handler.
/// Covers the happy path (code emitted + confirmed), a forged confirm (code but no confirm), and a
/// closed pairing window (nothing served).
@Suite(.timeLimit(.minutes(1))) struct SASPreambleIntegrationTests {
    private actor EventSink {
        private(set) var events: [HostRunnerEvent] = []
        func add(_ e: HostRunnerEvent) { events.append(e) }
        func snapshot() -> [HostRunnerEvent] { events }
    }

    private actor SourceKeySink {
        private(set) var keys: [String] = []
        func add(_ k: String) { keys.append(k) }
        func snapshot() -> [String] { keys }
    }

    /// Serve every accepted connection's SAS preamble, mirroring the production peek→serveSASPreamble
    /// dispatch and tolerating QUIC's dead double-delivery connection (its peek returns nil → close).
    private func runHost(_ listener: PortviewListener, hostCert: [UInt8],
                         sas: SASPairingControl, sink: EventSink,
                         sources: SourceKeySink? = nil) -> Task<Void, Never> {
        Task {
            await withTaskGroup(of: Void.self) { group in
                for await conn in listener.connections {
                    group.addTask {
                        let inbound = HostRunner.MessageReader(conn.inbound)
                        guard case .sasClientCommit(let commit)? = await inbound.next() else { conn.close(); return }
                        // Record the per-source limiter key at the same point production derives it
                        // (serveSASPreamble entry) — the per-source scheme silently degrades to the
                        // old shared-counter behavior if inbound QUIC endpoints don't resolve.
                        if let sources {
                            await sources.add(SASPairingControl.sourceKey(for: conn.resolvedRemoteEndpoint))
                        }
                        await HostRunner.serveSASPreamble(
                            conn, clientCommit: commit, inbound: inbound, hostCertSHA256: hostCert,
                            sas: sas, emit: { e in Task { await sink.add(e) } })
                    }
                }
            }
        }
    }

    private static func sawCode(_ events: [HostRunnerEvent], _ code: String) -> Bool {
        events.contains { if case .sasCode(let c) = $0 { c == code } else { false } }
    }
    private static func sawConfirmed(_ events: [HostRunnerEvent]) -> Bool {
        events.contains { if case .sasConfirmed = $0 { true } else { false } }
    }

    /// Drive the client side of the preamble; returns the derived code + the (nonces) for the confirm.
    private func clientHandshake(_ conn: PortviewConnection, certBytes: [UInt8]) async throws
        -> (code: String, clientNonce: [UInt8], hostNonce: [UInt8])? {
        let cn = SASCode.randomNonce()
        try await conn.send(.sasClientCommit(SASClientCommit(
            commit: SASCode.commit(nonce: cn, role: .client, certSHA256: certBytes))))
        var it = conn.inbound.makeAsyncIterator()
        guard case .sasHostCommit(let hc)? = await it.next() else { return nil }
        try await conn.send(.sasClientReveal(SASClientReveal(nonce: cn)))
        guard case .sasHostReveal(let hr)? = await it.next() else { return nil }
        #expect(SASCode.verify(commitment: hc.commit, nonce: hr.nonce, role: .host, certSHA256: certBytes))
        return (SASCode.derive(clientNonce: cn, hostNonce: hr.nonce, certSHA256: certBytes), cn, hr.nonce)
    }

    @Test func happyPathEmitsCodeAndConfirms() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let hostCert = [UInt8](try identity.certificateSHA256())
        let listener = try PortviewListener(quicIdentity: identity)
        let port = try await listener.start()
        let sas = SASPairingControl(); await sas.openWindow()
        let sink = EventSink()
        let sources = SourceKeySink()
        let host = runHost(listener, hostCert: hostCert, sas: sas, sink: sink, sources: sources)
        defer { host.cancel(); listener.cancel() }

        let (conn, captured) = try await PortviewConnection.connectCapturingCert(
            to: .hostPort(host: "127.0.0.1", port: port))
        defer { conn.close() }
        let certBytes = [UInt8](captured)
        #expect(certBytes == hostCert)  // loopback: captured cert is the real host's (no MITM)

        guard let result = try await clientHandshake(conn, certBytes: certBytes) else {
            Issue.record("preamble did not complete"); return
        }
        try await conn.send(.sasClientConfirm(SASClientConfirm(mac: SASCode.confirmation(
            clientNonce: result.clientNonce, hostNonce: result.hostNonce, certSHA256: certBytes))))

        var ok = false
        for _ in 0..<300 {
            let events = await sink.snapshot()
            if Self.sawCode(events, result.code) && Self.sawConfirmed(events) { ok = true; break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(ok)  // host emitted .sasCode(matching) AND .sasConfirmed

        // Per-source rate-limit key really resolves for an inbound QUIC connection — the first
        // host-side consumer of `resolvedRemoteEndpoint`; a nil endpoint would silently collapse
        // every source into one "unresolved" bucket (back to the shared-counter DoS).
        let keys = await sources.snapshot()
        #expect(!keys.isEmpty)
        #expect(!keys.contains("unresolved"))
    }

    @Test func forgedConfirmEmitsCodeButNotConfirmed() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let hostCert = [UInt8](try identity.certificateSHA256())
        let listener = try PortviewListener(quicIdentity: identity)
        let port = try await listener.start()
        let sas = SASPairingControl(); await sas.openWindow()
        let sink = EventSink()
        let host = runHost(listener, hostCert: hostCert, sas: sas, sink: sink)
        defer { host.cancel(); listener.cancel() }

        let (conn, captured) = try await PortviewConnection.connectCapturingCert(
            to: .hostPort(host: "127.0.0.1", port: port))
        defer { conn.close() }
        let certBytes = [UInt8](captured)
        guard let result = try await clientHandshake(conn, certBytes: certBytes) else {
            Issue.record("preamble did not complete"); return
        }
        var bad = SASCode.confirmation(clientNonce: result.clientNonce, hostNonce: result.hostNonce, certSHA256: certBytes)
        bad[0] ^= 0xFF
        try await conn.send(.sasClientConfirm(SASClientConfirm(mac: bad)))

        // Wait until the code is emitted, then confirm .sasConfirmed never follows the bad mac.
        for _ in 0..<300 {
            if Self.sawCode(await sink.snapshot(), result.code) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(200))
        let events = await sink.snapshot()
        #expect(Self.sawCode(events, result.code))
        #expect(!Self.sawConfirmed(events))  // forged confirm → no positive signal
    }

    @Test func closedWindowServesNothing() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let hostCert = [UInt8](try identity.certificateSHA256())
        let listener = try PortviewListener(quicIdentity: identity)
        let port = try await listener.start()
        let sas = SASPairingControl()  // NOT opened — pairing window closed
        let sink = EventSink()
        let host = runHost(listener, hostCert: hostCert, sas: sas, sink: sink)
        defer { host.cancel(); listener.cancel() }

        let (conn, captured) = try await PortviewConnection.connectCapturingCert(
            to: .hostPort(host: "127.0.0.1", port: port))
        defer { conn.close() }
        try await conn.send(.sasClientCommit(SASClientCommit(
            commit: SASCode.commit(nonce: SASCode.randomNonce(), role: .client, certSHA256: [UInt8](captured)))))

        // The host refuses (closes) without replying; the client sees the stream end and no code emits.
        var it = conn.inbound.makeAsyncIterator()
        let next = await it.next()
        #expect(next == nil)
        let events = await sink.snapshot()
        #expect(!events.contains { if case .sasCode = $0 { true } else { false } })
    }
}

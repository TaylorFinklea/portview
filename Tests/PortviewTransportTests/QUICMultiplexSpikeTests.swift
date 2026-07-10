import Testing
import Foundation
import Network
import Security
import CryptoKit
@testable import PortviewTransport
@testable import PortviewProtocol

// MARK: - Spike support

/// Thread-safe append-only bag for values collected from Network.framework callbacks.
private final class Bag<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []
    func append(_ value: Value) { lock.lock(); values.append(value); lock.unlock() }
    var snapshot: [Value] { lock.lock(); defer { lock.unlock() }; return values }
    var count: Int { snapshot.count }
}

/// One peer-opened QUIC stream accepted server-side, accumulating everything received on it.
private final class AcceptedStream: @unchecked Sendable {
    let connection: NWConnection
    private let lock = NSLock()
    private var _bytes: [UInt8] = []
    private var _sawComplete = false

    init(connection: NWConnection) { self.connection = connection }
    func append(_ data: Data) { lock.lock(); _bytes += [UInt8](data); lock.unlock() }
    func markComplete() { lock.lock(); _sawComplete = true; lock.unlock() }
    var bytes: [UInt8] { lock.lock(); defer { lock.unlock() }; return _bytes }
    var sawComplete: Bool { lock.lock(); defer { lock.unlock() }; return _sawComplete }
    var quicMetadata: NWProtocolQUIC.Metadata? {
        connection.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata
    }
}

private struct StreamOpenFailed: Error {}

/// Resume a continuation exactly once. `NWConnectionGroup` (unlike `NWConnection` in practice)
/// can deliver a second terminal state (`.failed` then `.cancelled`) before an in-handler
/// `stateUpdateHandler = nil` takes effect, which trips SWIFT TASK CONTINUATION MISUSE without
/// this guard.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    private func take() -> CheckedContinuation<T, Error>? {
        lock.lock(); defer { lock.unlock() }
        let taken = continuation
        continuation = nil
        return taken
    }
    func resume(returning value: T) { take()?.resume(returning: value) }
    func resume(throwing error: Error) { take()?.resume(throwing: error) }
}

/// Poll `condition` every 10ms until it holds or `deadline` elapses. QUIC handshakes take
/// seconds under parallel suite load, so spike deadlines are generous.
private func poll(deadline: Duration = .seconds(20), until condition: @escaping @Sendable () -> Bool) async throws {
    let clock = ContinuousClock()
    let end = clock.now.advanced(by: deadline)
    while clock.now < end {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    guard condition() else { throw TimeoutError() }
}

/// Start a client `NWConnectionGroup` (ONE QUIC tunnel; the handshake happens here) and wait
/// for `.ready`. Mirrors `PortviewConnection.awaitReady`'s cancellation shape so a timeout can
/// never wedge the continuation.
///
/// SPIKE FINDING (hard-won): the group NEVER leaves `.setup` — no state callback at all, no
/// error — unless `newConnectionHandler` is installed BEFORE `start(queue:)`. Also,
/// `NWConnection(from: group)` returns nil until the group has been started, and on loopback
/// the group passes through a transient `.waiting(ENETDOWN)` before `.ready`, so `.waiting`
/// must be ignored rather than treated as failure.
private func startReadyGroup(to endpoint: NWEndpoint, parameters: NWParameters,
                             queue: DispatchQueue,
                             inboundStreams: Bag<AcceptedStream>? = nil) async throws -> NWConnectionGroup {
    let group = NWConnectionGroup(with: NWMultiplexGroup(to: endpoint), using: parameters)
    group.newConnectionHandler = { conn in
        guard let inboundStreams else { return }
        let stream = AcceptedStream(connection: conn)
        inboundStreams.append(stream)
        conn.start(queue: queue)
        receiveLoop(on: stream)
    }
    try await withTimeout(.seconds(20)) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let once = ResumeOnce(cont)
                group.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        once.resume(returning: ())
                    case .failed(let error):
                        once.resume(throwing: error)
                    case .cancelled:
                        once.resume(throwing: CancellationError())
                    default:
                        break
                    }
                }
                group.start(queue: queue)
            }
        } onCancel: { group.cancel() }
    }
    group.stateUpdateHandler = nil
    return group
}

/// Open one stream on the tunnel (`NWConnection(from: group)`) and wait for `.ready`.
/// `options` picks per-stream QUIC options (e.g. `direction = .unidirectional`).
private func openReadyStream(in group: NWConnectionGroup, queue: DispatchQueue,
                             options: NWProtocolOptions? = nil) async throws -> NWConnection {
    guard let stream = NWConnection(from: group, using: options) else { throw StreamOpenFailed() }
    try await withTimeout(.seconds(20)) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let once = ResumeOnce(cont)
                stream.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        once.resume(returning: ())
                    case .failed(let error):
                        once.resume(throwing: error)
                    case .cancelled:
                        once.resume(throwing: CancellationError())
                    default:
                        break
                    }
                }
                stream.start(queue: queue)
            }
        } onCancel: { stream.cancel() }
    }
    stream.stateUpdateHandler = nil
    return stream
}

/// Async send of raw bytes; `context: .finalMessage` + `isComplete: true` half-closes the send
/// side (QUIC FIN on the stream).
private func send(_ bytes: [UInt8], on connection: NWConnection,
                  context: NWConnection.ContentContext = .defaultMessage,
                  isComplete: Bool = false) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        connection.send(content: Data(bytes), contentContext: context, isComplete: isComplete,
                        completion: .contentProcessed { error in
            if let error { cont.resume(throwing: error) } else { cont.resume() }
        })
    }
}

/// Continuous receive loop accumulating into `stream` until FIN/error.
private func receiveLoop(on stream: AcceptedStream) {
    stream.connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
        if let data, !data.isEmpty { stream.append(data) }
        if isComplete { stream.markComplete(); return }
        if error == nil { receiveLoop(on: stream) }
    }
}

/// Bare `NWListener` shaped like `PortviewListener`'s plumbing (every peer-opened stream arrives
/// as a fresh `NWConnection` via `newConnectionHandler`), but keeping the raw connection visible
/// so the spike can read QUIC/security metadata.
private func startBareListener(identity: TLSIdentity, queue: DispatchQueue,
                               into bag: Bag<AcceptedStream>) async throws -> (NWListener, NWEndpoint.Port) {
    let listener = try NWListener(using: QUICParameters.server(identity: identity))
    listener.newConnectionHandler = { conn in
        let accepted = AcceptedStream(connection: conn)
        bag.append(accepted)
        conn.start(queue: queue)
        receiveLoop(on: accepted)
    }
    let port = try await startListenerReady(listener, queue: queue)
    return (listener, port)
}

private func startListenerReady(_ listener: NWListener, queue: DispatchQueue) async throws -> NWEndpoint.Port {
    try await withTimeout(.seconds(20)) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NWEndpoint.Port, Error>) in
                let once = ResumeOnce(cont)
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if let port = listener.port {
                            once.resume(returning: port)
                        } else {
                            once.resume(throwing: PortviewListenerError.noBoundPort)
                        }
                    case .failed(let error):
                        once.resume(throwing: error)
                    case .cancelled:
                        once.resume(throwing: CancellationError())
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
            }
        } onCancel: { listener.cancel() }
    }
}

/// Client QUIC parameters identical to `QUICParameters.client` except the pinning verify block
/// also counts how many times it runs (spike question 2: once per tunnel or once per stream?).
private func countingPinnedClientParameters(pin: Data, evaluations: Bag<Int>) -> NWParameters {
    let q = NWProtocolQUIC.Options(alpn: [PortviewTransport.alpn])
    q.idleTimeout = 30_000
    q.initialMaxStreamsBidirectional = 16
    q.initialMaxStreamsUnidirectional = 4
    sec_protocol_options_set_verify_block(
        q.securityProtocolOptions,
        { _, secTrust, complete in
            evaluations.append(1)
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first else {
                complete(false)
                return
            }
            complete(Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data)) == pin)
        },
        DispatchQueue(label: "portview.spike.verify")
    )
    return NWParameters(quic: q)
}

// MARK: - Spike

/// Phase-0 spike for QUIC lane-splitting (spec: docs/superpowers/specs/2026-07-01-quic-lane-splitting.md).
/// Each test is evidence for one of the four spike questions; observed-but-undesired behavior is
/// documented in place rather than asserted away.
@Suite struct QUICMultiplexSpikeTests {
    /// Q1 (core): client `NWConnectionGroup` over QUIC → host's REAL `PortviewListener` (bare
    /// `NWListener(quicIdentity:)`). Both client-opened streams on the ONE tunnel arrive via the
    /// existing `newConnectionHandler` as independent `PortviewConnection`s, and each is fully
    /// bidirectional: the host's per-stream reply comes back on the right stream.
    @Test func groupOpenedStreamsArriveViaExistingListenerHandler() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let pin = try identity.certificateSHA256()
        let listener = try PortviewListener(quicIdentity: identity)
        let port = try await withTimeout(.seconds(20)) { try await listener.start() }

        // Serve every accepted connection concurrently (tolerating dead deliveries, as the real
        // host does); key the reply codec off the ClientHello deviceID so the ServerHello proves
        // per-stream routing rather than a merged byte stream.
        let serverTask = Task {
            for await connection in listener.connections {
                Task {
                    for await message in connection.inbound {
                        if case .clientHello(let hello) = message {
                            let codec: Codec = hello.deviceID == "MUX-A" ? .hevc : .h264
                            try? await connection.send(.serverHello(ServerHello(
                                protocolVersion: 1, displays: [], chosenCodec: codec)))
                        }
                    }
                }
            }
        }

        let queue = DispatchQueue(label: "portview.spike.tunnel")
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let group = try await startReadyGroup(
            to: endpoint, parameters: QUICParameters.client(pinnedCertificateSHA256: pin), queue: queue)

        let laneA = PortviewConnection(connection: try await openReadyStream(in: group, queue: queue), queue: queue)
        laneA.startReceiveLoop()
        let laneB = PortviewConnection(connection: try await openReadyStream(in: group, queue: queue), queue: queue)
        laneB.startReceiveLoop()

        try await laneA.send(.clientHello(ClientHello(
            protocolVersion: 1, deviceID: "MUX-A", deviceName: "Spike", codecs: [.hevc])))
        try await laneB.send(.clientHello(ClientHello(
            protocolVersion: 1, deviceID: "MUX-B", deviceName: "Spike", codecs: [.hevc])))

        let replyA = try await withTimeout(.seconds(20)) {
            for await message in laneA.inbound { return message }
            throw TimeoutError()
        }
        let replyB = try await withTimeout(.seconds(20)) {
            for await message in laneB.inbound { return message }
            throw TimeoutError()
        }

        serverTask.cancel()
        laneA.close()
        laneB.close()
        group.cancel()
        listener.cancel()

        guard case .serverHello(let helloA) = replyA, case .serverHello(let helloB) = replyB else {
            Issue.record("expected per-stream ServerHello replies, got \(replyA) / \(replyB)")
            return
        }
        #expect(helloA.chosenCodec == .hevc)
        #expect(helloB.chosenCodec == .h264)
    }

    /// Q1 (association): can the flat-listener host tell WHICH tunnel a stream belongs to from
    /// `sec_protocol_metadata`? Two tunnels from the same client: streams on the same tunnel
    /// share peer metadata, but the spike documents whether that metadata (and the per-tunnel
    /// `streamIdentifier` numbering, which restarts on every tunnel) can distinguish
    /// tunnel 1 from tunnel 2.
    @Test func secProtocolMetadataAssociationAcrossTunnels() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let pin = try identity.certificateSHA256()
        let queue = DispatchQueue(label: "portview.spike.metadata")
        let accepted = Bag<AcceptedStream>()
        let (listener, port) = try await startBareListener(identity: identity, queue: queue, into: accepted)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)

        let tunnel1 = try await startReadyGroup(
            to: endpoint, parameters: QUICParameters.client(pinnedCertificateSHA256: pin), queue: queue)
        let tunnel2 = try await startReadyGroup(
            to: endpoint, parameters: QUICParameters.client(pinnedCertificateSHA256: pin), queue: queue)

        let stream1a = try await openReadyStream(in: tunnel1, queue: queue)
        try await send([0xA1], on: stream1a)
        let stream1b = try await openReadyStream(in: tunnel1, queue: queue)
        try await send([0xA2], on: stream1b)
        let stream2 = try await openReadyStream(in: tunnel2, queue: queue)
        try await send([0xB1], on: stream2)

        try await poll {
            let bytes = accepted.snapshot.map(\.bytes)
            return bytes.contains([0xA1]) && bytes.contains([0xA2]) && bytes.contains([0xB1])
        }

        let server1a = accepted.snapshot.first { $0.bytes == [0xA1] }
        let server1b = accepted.snapshot.first { $0.bytes == [0xA2] }
        let server2 = accepted.snapshot.first { $0.bytes == [0xB1] }
        guard let m1a = server1a?.quicMetadata, let m1b = server1b?.quicMetadata,
              let m2 = server2?.quicMetadata else {
            Issue.record("QUIC metadata unavailable on accepted stream connections")
            tunnel1.cancel(); tunnel2.cancel(); listener.cancel()
            return
        }

        // Stream IDs are PER-TUNNEL: distinct within a tunnel (observed 4 then 8 — id 0 is
        // consumed internally, consistent with the dead "control" delivery), but both tunnels'
        // first app-opened bidi stream gets the SAME id — so the id alone cannot associate a
        // stream with its tunnel.
        #expect(m1a.streamIdentifier != m1b.streamIdentifier)
        #expect(m1a.streamIdentifier == m2.streamIdentifier)

        // peers_are_equal compares PEER identity, not tunnel identity: observed TRUE both within
        // a tunnel AND across two separate tunnels from the same client (which presents no cert
        // until mutual auth lands) — so sec_protocol_metadata CANNOT associate a stream with its
        // tunnel at the flat listener.
        let sameTunnel = sec_protocol_metadata_peers_are_equal(
            m1a.securityProtocolMetadata, m1b.securityProtocolMetadata)
        let crossTunnel = sec_protocol_metadata_peers_are_equal(
            m1a.securityProtocolMetadata, m2.securityProtocolMetadata)
        #expect(sameTunnel)
        #expect(crossTunnel,
                "peer metadata equality does not separate tunnels (same=\(sameTunnel) cross=\(crossTunnel))")

        tunnel1.cancel()
        tunnel2.cancel()
        listener.cancel()
    }

    /// Q1 (grouped delivery): a bare `NWListener` with `newConnectionGroupHandler` set delivers
    /// each inbound QUIC tunnel as an `NWConnectionGroup`, and the tunnel's streams arrive via
    /// THAT group's `newConnectionHandler` — native tunnel association, no token needed at the
    /// transport layer. Also documents where a LEGACY bare `NWConnection` dial (SAS preamble,
    /// old primary) lands when the group handler is installed.
    @Test func bareListenerGroupHandlerDeliversTunnelAsGroup() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let pin = try identity.certificateSHA256()
        let queue = DispatchQueue(label: "portview.spike.grouplistener")

        let listener = try NWListener(using: QUICParameters.server(identity: identity))
        let inboundGroups = Bag<NWConnectionGroup>()
        let groupedStreams = Bag<AcceptedStream>()
        // FINDING: setting newConnectionHandler AND newConnectionGroupHandler together makes the
        // listener fail to start with EINVAL — grouped delivery REPLACES flat delivery, it cannot
        // run alongside it. So a group-listener host must classify legacy bare dials (SAS, old
        // primary) out of single-stream groups; there is no flat fallback path.
        listener.newConnectionGroupHandler = { inboundGroup in
            inboundGroups.append(inboundGroup)
            inboundGroup.newConnectionHandler = { conn in
                let stream = AcceptedStream(connection: conn)
                groupedStreams.append(stream)
                conn.start(queue: queue)
                receiveLoop(on: stream)
            }
            inboundGroup.start(queue: queue)
        }
        let port = try await startListenerReady(listener, queue: queue)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)

        // Multiplexed client: one tunnel, two streams.
        let group = try await startReadyGroup(
            to: endpoint, parameters: QUICParameters.client(pinnedCertificateSHA256: pin), queue: queue)
        let stream1 = try await openReadyStream(in: group, queue: queue)
        try await send([0xC1], on: stream1)
        let stream2 = try await openReadyStream(in: group, queue: queue)
        try await send([0xC2], on: stream2)

        try await poll {
            let bytes = groupedStreams.snapshot.map(\.bytes)
            return bytes.contains([0xC1]) && bytes.contains([0xC2])
        }

        // Both streams arrive INSIDE the delivered group — the tunnel is the association key.
        #expect(inboundGroups.count == 1)
        #expect(groupedStreams.snapshot.filter { !$0.bytes.isEmpty }.count == 2)

        // Legacy bare dial into the SAME listener: documents whether old clients / the SAS
        // preamble still work when the host adopts a group handler.
        let bare = NWConnection(to: endpoint, using: QUICParameters.client(pinnedCertificateSHA256: pin))
        try await withTimeout(.seconds(20)) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    let once = ResumeOnce(cont)
                    bare.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            once.resume(returning: ())
                        case .failed(let error):
                            once.resume(throwing: error)
                        case .cancelled:
                            once.resume(throwing: CancellationError())
                        default:
                            break
                        }
                    }
                    bare.start(queue: queue)
                }
            } onCancel: { bare.cancel() }
        }
        bare.stateUpdateHandler = nil
        try await send([0xC3], on: bare)
        try await poll {
            groupedStreams.snapshot.contains { $0.bytes == [0xC3] }
        }
        // Observed: a legacy bare dial ALSO arrives via the group handler, as a (single-stream)
        // group — a group-listener host must classify that group's one stream as primary/SAS.
        #expect(groupedStreams.snapshot.contains { $0.bytes == [0xC3] })
        #expect(inboundGroups.count == 2)

        bare.cancel()
        group.cancel()
        listener.cancel()
    }

    /// Q2: cert pinning (the client's `sec_protocol_options_set_verify_block`) evaluates ONCE
    /// per tunnel — the TLS handshake belongs to the tunnel, and streams opened on it never
    /// re-run verification.
    @Test func certPinningEvaluatesOncePerTunnelNotPerStream() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let pin = try identity.certificateSHA256()
        let queue = DispatchQueue(label: "portview.spike.pincount")
        let accepted = Bag<AcceptedStream>()
        let (listener, port) = try await startBareListener(identity: identity, queue: queue, into: accepted)

        let evaluations = Bag<Int>()
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let group = try await startReadyGroup(
            to: endpoint, parameters: countingPinnedClientParameters(pin: pin, evaluations: evaluations),
            queue: queue)

        for payload in [[0xD1], [0xD2], [0xD3]] as [[UInt8]] {
            let stream = try await openReadyStream(in: group, queue: queue)
            try await send(payload, on: stream)
        }
        try await poll { accepted.snapshot.filter { !$0.bytes.isEmpty }.count == 3 }

        #expect(evaluations.count == 1)

        group.cancel()
        listener.cancel()
    }

    /// Q3: interplay with the QUIC double-delivery quirk (PortholeConnection.swift:52-54 — a bare
    /// dial makes `newConnectionHandler` fire twice, one dead "control" connection plus the real
    /// one). With a GROUP client the flat `PortviewListener` still over-delivers: exactly the
    /// N opened streams carry data, and any extras are dead connections the existing
    /// serve-each-concurrently pattern already tolerates.
    @Test func doubleDeliveryQuirkWithGroupClient() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let pin = try identity.certificateSHA256()
        let listener = try PortviewListener(quicIdentity: identity)
        let port = try await withTimeout(.seconds(20)) { try await listener.start() }

        let acceptedTotal = Bag<Int>()
        let helloIDs = Bag<String>()
        let serverTask = Task {
            for await connection in listener.connections {
                acceptedTotal.append(1)
                Task {
                    for await message in connection.inbound {
                        if case .clientHello(let hello) = message { helloIDs.append(hello.deviceID) }
                    }
                }
            }
        }

        let queue = DispatchQueue(label: "portview.spike.doubledelivery")
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let group = try await startReadyGroup(
            to: endpoint, parameters: QUICParameters.client(pinnedCertificateSHA256: pin), queue: queue)

        let laneA = PortviewConnection(connection: try await openReadyStream(in: group, queue: queue), queue: queue)
        laneA.startReceiveLoop()
        let laneB = PortviewConnection(connection: try await openReadyStream(in: group, queue: queue), queue: queue)
        laneB.startReceiveLoop()
        try await laneA.send(.clientHello(ClientHello(
            protocolVersion: 1, deviceID: "DD-1", deviceName: "Spike", codecs: [.hevc])))
        try await laneB.send(.clientHello(ClientHello(
            protocolVersion: 1, deviceID: "DD-2", deviceName: "Spike", codecs: [.hevc])))

        try await poll { helloIDs.count == 2 }
        // Absence window for extra (dead) deliveries — fixed sleep is fine for absence checks.
        try await Task.sleep(for: .milliseconds(500))

        // Data-carrying streams == streams opened; anything beyond is a dead delivery. Observed
        // consistently: 4 connections delivered for 2 opened streams (2 dead) — the quirk
        // doubles per stream, it doesn't disappear with a group client. The exact dead count is
        // an nw internal, so only the data-carrying invariant is asserted tightly.
        #expect(Set(helloIDs.snapshot) == ["DD-1", "DD-2"])
        let total = acceptedTotal.count
        #expect(total >= 2, "listener must deliver at least the data-carrying streams (saw \(total))")
        // The quirk itself: the spec's per-tunnel cap budgeting ("~2x the lane count") rests on
        // over-delivery persisting with a group client — pin it so an OS change that fixes the
        // quirk fails this canary and the budget gets revisited.
        #expect(total > 2, "double-delivery quirk no longer observed (saw \(total)) — revisit the per-tunnel cap budget in the lane-splitting spec")

        serverTask.cancel()
        laneA.close()
        laneB.close()
        group.cancel()
        listener.cancel()
    }

    /// Q4: half-closure. A client-opened UNIDIRECTIONAL stream (`direction = .unidirectional`,
    /// stream id ≡ 2 mod 4) delivers its payload and then `isComplete` after the final write
    /// (`.finalMessage` + `isComplete: true`). On a BIDI stream the same final write half-closes
    /// only the client→host direction — the host still sends host→client afterwards (the
    /// lane-preamble shape phase 1 wants). Direction misuse is NOT surfaced at the send site:
    /// a host send on the uni stream "succeeds" silently and the bytes simply never arrive.
    @Test func halfClosureSemanticsForUnidirectionalAndHalfClosedBidiStreams() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let pin = try identity.certificateSHA256()
        let queue = DispatchQueue(label: "portview.spike.halfclose")
        let accepted = Bag<AcceptedStream>()
        let (listener, port) = try await startBareListener(identity: identity, queue: queue, into: accepted)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)

        let group = try await startReadyGroup(
            to: endpoint, parameters: QUICParameters.client(pinnedCertificateSHA256: pin), queue: queue)

        // FINDING (hard-won): `NWConnection(from: group, using:)` REJECTS a freshly constructed
        // `NWProtocolQUIC.Options` — the stream fails straight to `.failed(ENETDOWN)`, with or
        // without an ALPN on it. The only accepted per-stream options object is the tunnel's
        // OWN options instance (living at `parameters.defaultProtocolStack.transportProtocol`,
        // NOT `applicationProtocols`), with `direction` flipped for the open and restored after
        // (the direction is captured at open time).
        guard let tunnelOptions = group.parameters.defaultProtocolStack.transportProtocol
                as? NWProtocolQUIC.Options else {
            Issue.record("no QUIC options found on group parameters")
            group.cancel(); listener.cancel()
            return
        }
        tunnelOptions.direction = .unidirectional
        let uni = try await openReadyStream(in: group, queue: queue, options: tunnelOptions)
        tunnelOptions.direction = .bidirectional
        let uniPayload: [UInt8] = [0x5A, 0x5A, 0x5A]
        try await send(uniPayload, on: uni, context: .finalMessage, isComplete: true)

        // Bidi stream: client writes a preamble-shaped payload, half-closes its send side,
        // and must STILL receive host→client bytes afterwards.
        let bidi = try await openReadyStream(in: group, queue: queue)
        let clientSide = AcceptedStream(connection: bidi)
        receiveLoop(on: clientSide)
        let preamble: [UInt8] = [0x02, 0xAB, 0xCD, 0xEF]
        try await send(preamble, on: bidi, context: .finalMessage, isComplete: true)

        try await poll { accepted.snapshot.contains { $0.bytes == uniPayload && $0.sawComplete } }
        try await poll { accepted.snapshot.contains { $0.bytes == preamble && $0.sawComplete } }

        guard let uniServer = accepted.snapshot.first(where: { $0.bytes == uniPayload }),
              let bidiServer = accepted.snapshot.first(where: { $0.bytes == preamble }) else {
            Issue.record("half-closed streams did not surface server-side")
            group.cancel(); listener.cancel()
            return
        }

        // QUIC stream-id parity proves the direction really was negotiated per stream:
        // client-initiated bidi ids ≡ 0 (mod 4), client-initiated uni ids ≡ 2 (mod 4).
        if let m = uniServer.quicMetadata {
            #expect(m.streamIdentifier % 4 == 2)
        } else {
            Issue.record("no QUIC metadata on the unidirectional stream")
        }
        if let m = bidiServer.quicMetadata {
            #expect(m.streamIdentifier % 4 == 0)
        }

        // Host→client still flows on the client-half-closed bidi stream…
        let reply: [UInt8] = [0xEE, 0xFF]
        try await send(reply, on: bidiServer.connection)
        try await poll { clientSide.bytes == reply }
        #expect(clientSide.bytes == reply)

        // …while a host send on the client-opened UNI stream does NOT error — the completion
        // fires with nil error and the bytes just vanish (the stream has no host→client
        // direction). Direction violations are invisible at the send site, so lane code must
        // enforce direction by protocol, never by trusting send errors. The absence check uses
        // a fixed sleep (allowed for absence assertions).
        let uniClientSide = AcceptedStream(connection: uni)
        receiveLoop(on: uniClientSide)
        var hostSendOnUniErrored = false
        do { try await send([0xBA, 0xD0], on: uniServer.connection) } catch { hostSendOnUniErrored = true }
        #expect(!hostSendOnUniErrored)
        try await Task.sleep(for: .milliseconds(500))
        #expect(uniClientSide.bytes.isEmpty)

        group.cancel()
        listener.cancel()
    }
}

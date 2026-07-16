// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import Network
@testable import PortviewTransport
@testable import PortviewProtocol

// MARK: - Support

private struct LaneStreamClosedError: Error {}

/// Next inbound message on `connection`, bounded by `timeout`; throws if the stream finishes
/// (stream closed by the peer) before yielding one.
private func nextMessage(on connection: PortviewConnection,
                         timeout: Duration = .seconds(20)) async throws -> AnyMessage {
    try await withTimeout(timeout) {
        for await message in connection.inbound { return message }
        throw LaneStreamClosedError()
    }
}

/// Await `connection`'s inbound stream FINISHING (the host closed that stream), bounded by
/// `timeout`. A stream that stays open (e.g. a lane that wrongly bound) times the test out.
private func expectClosed(_ connection: PortviewConnection,
                          timeout: Duration = .seconds(20)) async throws {
    try await withTimeout(timeout) {
        for await _ in connection.inbound {}
    }
}

/// Thread-safe holder for the lanes a test host has bound (appends land on server-side tasks).
private final class BoundLanes: @unchecked Sendable {
    private let lock = NSLock()
    private var lanes: [AcceptedLane] = []
    func append(_ lane: AcceptedLane) { lock.lock(); lanes.append(lane); lock.unlock() }
    var snapshot: [AcceptedLane] { lock.lock(); defer { lock.unlock() }; return lanes }
}

/// Deterministic per-lane marker frame: the message TYPE proves which lane the frame rode
/// (video/audio/stats payloads are distinguishable), the embedded `marker` proves which round
/// sent it. `AnyMessage` is Equatable, so tests compare against the same construction.
private func markerFrame(for lane: Lane, marker: UInt64) -> AnyMessage? {
    switch lane {
    case .video:
        return .videoFrame(VideoFrame(sequence: marker, ptsMicros: 0, isKeyframe: true,
                                      displayID: 1, width: 8, height: 8, data: [0xAA]))
    case .audio:
        return .audioFrame(AudioFrame(sampleRate: UInt32(marker), channels: 1, ptsMicros: 0, data: [0xBB]))
    case .stats:
        return .qualityStats(QualityStats(
            displayID: UInt32(marker), encoderWidth: 0, encoderHeight: 0, configuredBitrate: 0,
            encodedMbpsX100: 0, fpsX100: 0, averageFrameBytes: 0, keyframes: 0,
            averageEncodeMsX100: 0, viewportX: 0, viewportY: 0, viewportW: 0, viewportH: 0))
    default:
        return nil
    }
}

/// Serve a multiplexed test host: every frame-path connection gets the existing reactive shape —
/// on `ClientHello`, authorize lanes with `token` (collecting binds into `bound` and sending a
/// marker-0 frame on each as it binds), THEN reply `ServerHello` carrying the token; on `Ping`,
/// reply `Pong` on primary and send a fresh marker frame (the ping's `sendMicros`) on every
/// bound lane — so a test can prove primary + all lanes still flow at any point.
private func serveMultiplexedHost(_ listener: PortviewListener, token: [UInt8],
                                  bound: BoundLanes) -> Task<Void, Never> {
    Task {
        for await connection in listener.connections {
            Task {
                for await message in connection.inbound {
                    switch message {
                    case .clientHello:
                        guard let lanes = connection.acceptLanes(sessionToken: token) else { continue }
                        Task {
                            for await accepted in lanes {
                                bound.append(accepted)
                                if let frame = markerFrame(for: accepted.lane, marker: 0) {
                                    try? await accepted.connection.send(frame)
                                }
                            }
                        }
                        try? await connection.send(.serverHello(ServerHello(
                            protocolVersion: ProtocolVersion.laneVersion, displays: [],
                            chosenCodec: .hevc, sessionToken: token)))
                    case .ping(let ping):
                        try? await connection.send(.pong(Pong(sendMicros: ping.sendMicros, hostUptimeMicros: 0)))
                        for accepted in bound.snapshot {
                            if let frame = markerFrame(for: accepted.lane, marker: ping.sendMicros) {
                                try? await accepted.connection.send(frame)
                            }
                        }
                    default:
                        break
                    }
                }
            }
        }
    }
}

// MARK: - Classifier guard

/// Pins the invariant the multiplexed accept path's first-byte classifier rests on (see
/// `StreamClassifier`): **no legitimate first frame has `bodyLength <= 6`**, so every `Lane`
/// raw value classifies to the lane-preamble path and every real first-frame encoding classifies
/// to the frame path. A naive "unknown lane byte → close" without the frame escape would close
/// first-byte-16 (old primaries) and first-byte-33 (SAS pairing) streams — killing old clients
/// and pairing entirely.
@Suite struct LaneStreamClassifierTests {
    /// The REAL first-frame encodings (same constructions as their GoldenFrameTests vectors):
    /// their first byte — the varint `bodyLength` — must exceed every lane-preamble byte.
    @Test func realFirstFrameEncodingsClassifyToTheFramePath() throws {
        let clientHello = Frame.encodeAny(.clientHello(ClientHello(
            protocolVersion: 1, deviceID: "d1", deviceName: "iPhone", codecs: [.h264, .hevc])))
        let sasCommit = Frame.encodeAny(.sasClientCommit(SASClientCommit(
            commit: Array(repeating: UInt8(0xAB), count: 32))))

        let helloFirst = try #require(clientHello.first)
        let sasFirst = try #require(sasCommit.first)
        // Golden first bytes (GoldenFrameTests): primary handshake = 16, SAS commit = 33.
        #expect(helloFirst == 16)
        #expect(sasFirst == 33)
        #expect(helloFirst > StreamClassifier.maxLanePreambleByte)
        #expect(sasFirst > StreamClassifier.maxLanePreambleByte)
        #expect(StreamClassifier.classify(firstByte: helloFirst) == .frame)
        #expect(StreamClassifier.classify(firstByte: sasFirst) == .frame)
    }

    @Test func everyLaneRawValueClassifiesToTheLanePreamblePath() {
        // The boundary is Lane's maximum raw value — wire-frozen at 6 (stats). If a new Lane
        // case ever moves this, the invariant must be re-proven against every legitimate
        // first-frame encoding before shipping.
        #expect(StreamClassifier.maxLanePreambleByte == 6)
        for lane in Lane.allCases {
            #expect(StreamClassifier.classify(firstByte: lane.rawValue) == .lanePreamble)
        }
        // First byte just past the lane range already belongs to the frame path.
        #expect(StreamClassifier.classify(firstByte: StreamClassifier.maxLanePreambleByte + 1) == .frame)
    }
}

@Suite struct LaneSessionTokenTests {
    @Test func mintsPreambleLengthTokensThatDiffer() {
        let a = LaneSessionToken.mint()
        let b = LaneSessionToken.mint()
        #expect(a.count == LanePreamble.tokenLength)
        #expect(b.count == LanePreamble.tokenLength)
        #expect(a != Array(repeating: UInt8(0), count: LanePreamble.tokenLength))
        #expect(a != b)
    }
}

// MARK: - Loopback integration

/// Loopback integration for the transport layer of QUIC lane-splitting (bead w6n.3): a client
/// `PortviewTunnel` (NWConnectionGroup) against a multiplexed `PortviewListener` (grouped
/// delivery — the spike's native tunnel-association mechanism).
@Suite struct LaneTransportTests {
    /// Acceptance core: three lanes open with a valid token and frames flow PER-LANE (each lane
    /// receives exactly its own message type/marker); a garbage preamble (valid lane byte, wrong
    /// token) closes ONLY its stream; a duplicate already-bound lane is rejected; and afterwards
    /// the primary and all three lanes still flow.
    @Test func multiLaneFramesFlowPerLaneAndGarbageOrDuplicateClosesOnlyItsStream() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let pin = try identity.certificateSHA256()
        let listener = try PortviewListener(quicIdentity: identity, multiplexed: true)
        let port = try await withTimeout(.seconds(20)) { try await listener.start() }

        let token = LaneSessionToken.mint()
        let bound = BoundLanes()
        let serverTask = serveMultiplexedHost(listener, token: token, bound: bound)

        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let tunnel = try await PortviewTunnel.connectQUIC(to: endpoint, pinnedCertificateSHA256: pin)
        let primary = try await tunnel.openPrimaryStream()
        try await primary.send(.clientHello(ClientHello(
            protocolVersion: ProtocolVersion.laneVersion, deviceID: "LANE", deviceName: "LaneTest",
            codecs: [.hevc])))
        let helloReply = try await nextMessage(on: primary)
        guard case .serverHello(let hello) = helloReply else {
            Issue.record("expected ServerHello on primary, got \(helloReply)")
            tunnel.cancel(); listener.cancel(); serverTask.cancel()
            return
        }
        let sessionToken = try #require(hello.sessionToken)

        // Open the three phase-1 lanes; each must receive ITS marker-0 frame (type + marker
        // prove per-lane routing, not a merged stream).
        let video = try await tunnel.openLane(.video, sessionToken: sessionToken)
        let audio = try await tunnel.openLane(.audio, sessionToken: sessionToken)
        let stats = try await tunnel.openLane(.stats, sessionToken: sessionToken)
        #expect(try await nextMessage(on: video) == markerFrame(for: .video, marker: 0))
        #expect(try await nextMessage(on: audio) == markerFrame(for: .audio, marker: 0))
        #expect(try await nextMessage(on: stats) == markerFrame(for: .stats, marker: 0))

        // Garbage preamble: valid lane byte, WRONG token → the host closes THAT stream only.
        let garbage = try await tunnel.openLane(.clipboard, sessionToken: LaneSessionToken.mint())
        try await expectClosed(garbage)

        // Duplicate of an already-bound lane, even with the VALID token → rejected.
        let duplicate = try await tunnel.openLane(.video, sessionToken: sessionToken)
        try await expectClosed(duplicate)

        // Primary and all three original lanes still flow after the rejected streams.
        try await primary.send(.ping(Ping(sendMicros: 7)))
        #expect(try await nextMessage(on: primary) == .pong(Pong(sendMicros: 7, hostUptimeMicros: 0)))
        #expect(try await nextMessage(on: video) == markerFrame(for: .video, marker: 7))
        #expect(try await nextMessage(on: audio) == markerFrame(for: .audio, marker: 7))
        #expect(try await nextMessage(on: stats) == markerFrame(for: .stats, marker: 7))

        // Exactly the three lanes ever bound (the duplicate never yielded a fourth).
        #expect(bound.snapshot.map(\.lane).sorted { $0.rawValue < $1.rawValue } == [.video, .audio, .stats])

        serverTask.cancel()
        primary.close()
        tunnel.cancel()
        listener.cancel()
    }

    /// Secondary streams are accepted only AFTER the primary handshake completes: authorization
    /// happens then (`acceptLanes`), so with no handshake there is no authorized token and a lane
    /// open — even a well-formed one — is closed.
    @Test func laneOpenedBeforeAnyAuthorizationIsClosed() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let pin = try identity.certificateSHA256()
        let listener = try PortviewListener(quicIdentity: identity, multiplexed: true)
        let port = try await withTimeout(.seconds(20)) { try await listener.start() }

        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let tunnel = try await PortviewTunnel.connectQUIC(to: endpoint, pinnedCertificateSHA256: pin)
        let premature = try await tunnel.openLane(.video, sessionToken: LaneSessionToken.mint())
        try await expectClosed(premature)

        tunnel.cancel()
        listener.cancel()
    }

    /// Compat gate: a LEGACY bare `NWConnection` dial into the multiplexed listener arrives as a
    /// single-stream group, classifies down the frame path (ClientHello first byte = 16 > 6),
    /// and is served through the EXISTING `connections` path unchanged — old clients keep
    /// working when the host adopts grouped delivery.
    @Test func legacyBareDialIsServedUnchangedByMultiplexedListener() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let pin = try identity.certificateSHA256()
        let listener = try PortviewListener(quicIdentity: identity, multiplexed: true)
        let port = try await withTimeout(.seconds(20)) { try await listener.start() }

        let serverTask = Task {
            for await connection in listener.connections {
                Task {
                    for await message in connection.inbound {
                        if case .clientHello = message {
                            try? await connection.send(.serverHello(ServerHello(
                                protocolVersion: 1, displays: [], chosenCodec: .hevc)))
                        }
                    }
                }
            }
        }

        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let legacy = try await withTimeout(.seconds(20)) {
            try await PortviewConnection.connectQUIC(to: endpoint, pinnedCertificateSHA256: pin)
        }
        try await legacy.send(.clientHello(ClientHello(
            protocolVersion: 1, deviceID: "OLD", deviceName: "Legacy", codecs: [.hevc])))
        let reply = try await nextMessage(on: legacy)

        serverTask.cancel()
        legacy.close()
        listener.cancel()

        guard case .serverHello(let hello) = reply else {
            Issue.record("expected ServerHello for the legacy dial, got \(reply)")
            return
        }
        #expect(hello.chosenCodec == .hevc)
        #expect(hello.sessionToken == nil)
    }

    /// Slow-loris bound on stream open: preamble bytes are raw pre-framing bytes, outside the
    /// decoded-message deadline helper's reach, so the accept path applies its own bounded
    /// RAW-read deadline — a stream that stalls mid-preamble is closed when it expires.
    @Test func stalledPreambleStreamIsClosedByTheRawReadDeadline() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let pin = try identity.certificateSHA256()
        let listener = try PortviewListener(parameters: QUICParameters.server(identity: identity),
                                            serviceName: nil, port: nil, multiplexed: true,
                                            lanePreambleDeadline: .milliseconds(300))
        let port = try await withTimeout(.seconds(20)) { try await listener.start() }

        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let tunnel = try await PortviewTunnel.connectQUIC(to: endpoint, pinnedCertificateSHA256: pin)
        // One lane byte, then silence: the preamble never completes.
        let stalled = try await tunnel.openStream()
        try await stalled.sendRaw([Lane.video.rawValue])
        stalled.startReceiveLoop()
        try await expectClosed(stalled)

        tunnel.cancel()
        listener.cancel()
    }

    /// A ZERO-byte idle stream must not take the tunnel down when the preamble deadline passes.
    /// In the wild (device session 2026-07-16) the iOS client's tunnel carries an extra stream
    /// that never sends a byte; the accept path's deadline-cancel of that never-ready stream
    /// cascaded "Socket is not connected" through the shared QUIC stack ~1.3s later, killing the
    /// LIVE primary (56fps session died mid-stream, client saw a frozen frame). Zero-byte streams
    /// are parked instead: they cost nothing until bytes arrive (classification is byte-driven)
    /// and die with the tunnel. The deadline still bounds PARTIAL preambles (slow-loris — the
    /// `stalledPreambleStreamIsClosedByTheRawReadDeadline` case above).
    @Test func idleZeroByteStreamDoesNotKillTheTunnelWhenTheDeadlinePasses() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let pin = try identity.certificateSHA256()
        let listener = try PortviewListener(parameters: QUICParameters.server(identity: identity),
                                            serviceName: nil, port: nil, multiplexed: true,
                                            lanePreambleDeadline: .milliseconds(300))
        let port = try await withTimeout(.seconds(20)) { try await listener.start() }

        let serverTask = Task {
            for await connection in listener.connections {
                Task {
                    for await message in connection.inbound {
                        switch message {
                        case .clientHello:
                            try? await connection.send(.serverHello(ServerHello(
                                protocolVersion: 1, displays: [], chosenCodec: .hevc)))
                        case .ping(let ping):
                            try? await connection.send(.pong(Pong(sendMicros: ping.sendMicros,
                                                                  hostUptimeMicros: 0)))
                        default:
                            break
                        }
                    }
                }
            }
        }

        // Production shape: a v1 client on a tunnel — primary stream only, lanes dormant.
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let tunnel = try await PortviewTunnel.connectQUIC(to: endpoint, pinnedCertificateSHA256: pin)
        let primary = try await tunnel.openPrimaryStream()
        try await primary.send(.clientHello(ClientHello(
            protocolVersion: 1, deviceID: "IDLE", deviceName: "IdleStream", codecs: [.hevc])))
        let helloReply = try await nextMessage(on: primary)
        guard case .serverHello = helloReply else {
            Issue.record("expected ServerHello on primary, got \(helloReply)")
            tunnel.cancel(); listener.cancel(); serverTask.cancel()
            return
        }

        // The phantom: an extra stream that never sends a single byte.
        let phantom = try await tunnel.openStream()

        // Outlive the preamble deadline (300ms) plus the observed cancel→cascade gap (~1.3s).
        try await Task.sleep(for: .seconds(2))

        // The live session must still flow.
        try await primary.send(.ping(Ping(sendMicros: 99)))
        #expect(try await nextMessage(on: primary) == .pong(Pong(sendMicros: 99, hostUptimeMicros: 0)))

        phantom.close()
        serverTask.cancel()
        primary.close()
        tunnel.cancel()
        listener.cancel()
    }

    /// App-level per-tunnel cap: one tunnel gets `AcceptedTunnel.maxLanePathStreams` lane-path
    /// attempts; past that, even a VALID lane open is closed — a flood of garbage preambles
    /// burns only the flooding tunnel's own budget.
    @Test func lanePathAttemptsBeyondThePerTunnelCapAreClosed() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let pin = try identity.certificateSHA256()
        let listener = try PortviewListener(quicIdentity: identity, multiplexed: true)
        let port = try await withTimeout(.seconds(20)) { try await listener.start() }

        let token = LaneSessionToken.mint()
        let bound = BoundLanes()
        let serverTask = serveMultiplexedHost(listener, token: token, bound: bound)

        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let tunnel = try await PortviewTunnel.connectQUIC(to: endpoint, pinnedCertificateSHA256: pin)
        let primary = try await tunnel.openPrimaryStream()
        try await primary.send(.clientHello(ClientHello(
            protocolVersion: ProtocolVersion.laneVersion, deviceID: "CAP", deviceName: "CapTest",
            codecs: [.hevc])))
        let helloReply = try await nextMessage(on: primary)
        guard case .serverHello(let hello) = helloReply, let sessionToken = hello.sessionToken else {
            Issue.record("expected token-carrying ServerHello, got \(helloReply)")
            tunnel.cancel(); listener.cancel(); serverTask.cancel()
            return
        }

        // Burn the whole per-tunnel lane budget with wrong-token preambles (each closed).
        for _ in 0..<AcceptedTunnel.maxLanePathStreams {
            let garbage = try await tunnel.openLane(.video, sessionToken: LaneSessionToken.mint())
            try await expectClosed(garbage)
        }
        // The budget is spent: a valid open on the same tunnel is closed instead of binding.
        let overCap = try await tunnel.openLane(.video, sessionToken: sessionToken)
        try await expectClosed(overCap)
        #expect(bound.snapshot.isEmpty)

        serverTask.cancel()
        primary.close()
        tunnel.cancel()
        listener.cancel()
    }
}

// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import Network
@testable import PortviewTransport
@testable import PortviewProtocol

// MARK: - Support

private func videoFrame(_ sequence: UInt64) -> VideoFrame {
    VideoFrame(sequence: sequence, ptsMicros: 0, isKeyframe: true,
               displayID: 1, width: 8, height: 8, data: [0xAA])
}

private func audioMarker(_ marker: UInt32) -> AudioFrame {
    AudioFrame(sampleRate: marker, channels: 1, ptsMicros: 0, data: [0xBB])
}

private func statsMarker(_ marker: UInt32) -> QualityStats {
    QualityStats(displayID: marker, encoderWidth: 0, encoderHeight: 0, configuredBitrate: 0,
                 encodedMbpsX100: 0, fpsX100: 0, averageFrameBytes: 0, keyframes: 0,
                 averageEncodeMsX100: 0, viewportX: 0, viewportY: 0, viewportW: 0, viewportH: 0)
}

/// Poll `condition` every 10ms until it holds or `deadline` elapses; returns the final verdict.
private func poll(deadline: Duration = .seconds(5),
                  _ condition: @escaping @Sendable () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let end = clock.now.advanced(by: deadline)
    while clock.now < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Drains a merged inbound stream into a thread-safe transcript the test polls against.
private final class MergedCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [AnyMessage] = []
    private var ended = false

    func collect(_ stream: AsyncStream<AnyMessage>) -> Task<Void, Never> {
        Task {
            for await message in stream { append(message) }
            markEnded()
        }
    }

    private func append(_ message: AnyMessage) { lock.lock(); messages.append(message); lock.unlock() }
    private func markEnded() { lock.lock(); ended = true; lock.unlock() }

    var snapshot: [AnyMessage] { lock.lock(); defer { lock.unlock() }; return messages }
    var isEnded: Bool { lock.lock(); defer { lock.unlock() }; return ended }
    var videoSequences: [UInt64] {
        snapshot.compactMap { if case .videoFrame(let f) = $0 { return f.sequence }; return nil }
    }
    var audioMarkers: [UInt32] {
        snapshot.compactMap { if case .audioFrame(let f) = $0 { return f.sampleRate }; return nil }
    }
    var statsMarkers: [UInt32] {
        snapshot.compactMap { if case .qualityStats(let s) = $0 { return s.displayID }; return nil }
    }
    var pongMarkers: [UInt64] {
        snapshot.compactMap { if case .pong(let p) = $0 { return p.sendMicros }; return nil }
    }
    var firstServerHello: ServerHello? {
        for message in snapshot { if case .serverHello(let hello) = message { return hello } }
        return nil
    }
}

/// Lane-capable test host over a multiplexed listener (mirrors LaneTransportTests'
/// `serveMultiplexedHost` idiom, plus direct handles so tests can script frames onto the primary
/// or any bound lane): on `ClientHello` — authorize lanes with `token` (unless `authorizeLanes`
/// is false: the lane-open-failure host, whose lane binds are all rejected), THEN reply a
/// token-carrying `ServerHello`; on `Ping` — reply `Pong`; on `Bye` — close that connection.
private final class LaneHostHarness: @unchecked Sendable {
    let token: [UInt8]
    private let lock = NSLock()
    private var primaryConnection: PortviewConnection?
    private var boundLanes: [Lane: PortviewConnection] = [:]
    private var serveTask: Task<Void, Never>?

    init(token: [UInt8] = LaneSessionToken.mint()) {
        self.token = token
    }

    var primary: PortviewConnection? { lock.lock(); defer { lock.unlock() }; return primaryConnection }
    func lane(_ lane: Lane) -> PortviewConnection? { lock.lock(); defer { lock.unlock() }; return boundLanes[lane] }
    var boundLaneSet: Set<Lane> { lock.lock(); defer { lock.unlock() }; return Set(boundLanes.keys) }

    private func setPrimary(_ connection: PortviewConnection) {
        lock.lock(); primaryConnection = connection; lock.unlock()
    }

    private func bind(_ accepted: AcceptedLane) {
        lock.lock(); boundLanes[accepted.lane] = accepted.connection; lock.unlock()
    }

    func serve(_ listener: PortviewListener, authorizeLanes: Bool = true) {
        let token = token
        // Strong self: the harness outlives its serve task (tests cancel it at the end).
        serveTask = Task { [self] in
            for await connection in listener.connections {
                Task {
                    for await message in connection.inbound {
                        switch message {
                        case .clientHello:
                            setPrimary(connection)
                            if authorizeLanes, let lanes = connection.acceptLanes(sessionToken: token) {
                                Task { for await accepted in lanes { bind(accepted) } }
                            }
                            try? await connection.send(.serverHello(ServerHello(
                                protocolVersion: ProtocolVersion.laneVersion, displays: [],
                                chosenCodec: .hevc, sessionToken: token)))
                        case .ping(let ping):
                            try? await connection.send(.pong(Pong(sendMicros: ping.sendMicros, hostUptimeMicros: 0)))
                        case .bye:
                            connection.close()
                        default:
                            break
                        }
                    }
                }
            }
        }
    }

    func cancel() { serveTask?.cancel() }
}

// MARK: - Stale-video guard (pure)

/// Reference-typed shim so `#expect` (whose expansion can't call a mutating member) can drive
/// the guard struct.
private final class GuardBox {
    private var stale = StaleVideoGuard()
    func admit(_ sequence: UInt64, _ source: MergeSource) -> Bool {
        stale.admit(videoFrame(sequence), from: source)
    }

    func admit(_ sequence: UInt64, pts: UInt64, _ source: MergeSource) -> Bool {
        stale.admit(VideoFrame(sequence: sequence, ptsMicros: pts, isKeyframe: true,
                               displayID: 1, width: 8, height: 8, data: [0xAA]), from: source)
    }
}

/// Pins the merge-point ordering rule for video across the lane→primary flip: same-source frames
/// are always current (per-stream QUIC ordering — a sequence drop there is a legitimate
/// host-side pump restart), cross-source frames must carry a NEWER sequence than the last
/// accepted one or they are stale stragglers.
@Suite struct StaleVideoGuardTests {
    @Test func firstFrameIsAcceptedFromAnySourceEvenAtSequenceZero() {
        #expect(GuardBox().admit(0, .lane(.video)))
        #expect(GuardBox().admit(0, .primary))
    }

    @Test func sameSourceIsAlwaysCurrentIncludingAPumpRestartSequenceReset() {
        let g = GuardBox()
        #expect(g.admit(1, .lane(.video)))
        #expect(g.admit(2, .lane(.video)))
        // A display switch restarts pumpVideo host-side: sequence legitimately RESETS on the
        // same stream. "Highest sequence wins" would blackhole the rest of the session here.
        #expect(g.admit(1, .lane(.video)))
        #expect(g.admit(2, .lane(.video)))
    }

    @Test func flipToPrimaryDeliversFreshFramesAndDropsLateLaneStragglers() {
        let g = GuardBox()
        #expect(g.admit(1, .lane(.video)))
        #expect(g.admit(2, .lane(.video)))
        #expect(g.admit(3, .lane(.video)))
        // The flip: the lane died and newer frames arrive on primary.
        #expect(g.admit(4, .primary))
        #expect(g.admit(5, .primary))
        // Late stragglers from before the flip — including a cross-stream duplicate of the
        // last accepted sequence — are stale and dropped.
        #expect(!g.admit(3, .lane(.video)))
        #expect(!g.admit(5, .lane(.video)))
        // Primary keeps flowing, and a genuinely newer lane frame is accepted again.
        #expect(g.admit(6, .primary))
        #expect(g.admit(7, .lane(.video)))
    }

    @Test func pumpRestartAfterAFlipRecoversOnTheNewSource() {
        let g = GuardBox()
        #expect(g.admit(100, .lane(.video)))
        #expect(g.admit(101, .primary)) // flip
        // Pump restart on primary (same source): the reset is accepted and re-bases the guard,
        // so later frames aren't compared against the pre-restart high-water sequence.
        #expect(g.admit(1, .primary))
        #expect(g.admit(2, .primary))
    }

    /// The blackhole case: a host pump restart landing INSIDE the flip window (no primary frame
    /// admitted between the last lane frame and the restart) resets the sequence counter, but
    /// capture PTS is host-clock monotonic across pump restarts — the guard must recover by PTS
    /// instead of dropping every post-restart frame (video freeze with live audio).
    @Test func pumpRestartLandingInsideTheFlipWindowRecoversByPTS() {
        let g = GuardBox()
        #expect(g.admit(500, pts: 1_000_000, .lane(.video)))
        #expect(g.admit(1, pts: 1_016_666, .primary))
        #expect(g.admit(2, pts: 1_033_333, .primary))
    }

    @Test func stragglerOlderOnBothAxesStillDrops() {
        let g = GuardBox()
        #expect(g.admit(500, pts: 1_000_000, .lane(.video)))
        #expect(g.admit(501, pts: 1_016_666, .primary))
        // Older sequence AND older PTS: a genuine pre-flip straggler, still dropped.
        #expect(!g.admit(499, pts: 999_983, .lane(.video)))
    }
}

// MARK: - Merge rendezvous

@Suite struct LaneMergeTests {
    /// Rendezvous contract: each producer's messages arrive in its own send order (per-lane
    /// order is the app's ordering contract; cross-lane interleaving is free).
    @Test func preservesPerProducerFIFOAcrossConcurrentProducers() async throws {
        let merge = LaneMerge()
        let pings = Task {
            for i in 1...20 { await merge.send(.ping(Ping(sendMicros: UInt64(i))), from: .primary) }
        }
        let audio = Task {
            for i in 1...20 { await merge.send(.audioFrame(audioMarker(UInt32(i))), from: .lane(.audio)) }
        }
        let (pingOrder, audioOrder) = try await withTimeout(.seconds(10)) {
            var pings: [UInt64] = []
            var audioMarkers: [UInt32] = []
            for _ in 0..<40 {
                switch await merge.next() {
                case .ping(let p): pings.append(p.sendMicros)
                case .audioFrame(let a): audioMarkers.append(a.sampleRate)
                default: Issue.record("unexpected merged message")
                }
            }
            return (pings, audioMarkers)
        }
        #expect(pingOrder == (1...20).map(UInt64.init))
        #expect(audioOrder == (1...20).map(UInt32.init))
        await pings.value
        await audio.value
        merge.finish()
    }

    /// The stale-video drop happens INSIDE the hand-off (admit order == delivery order): a stale
    /// frame is dropped without suspending its sender, so a sequential sender can't wedge on it.
    @Test func staleVideoIsDroppedAtTheMergePointWithoutBlockingTheSender() async throws {
        let merge = LaneMerge()
        let collector = Task { () -> [UInt64] in
            var sequences: [UInt64] = []
            while let message = await merge.next() {
                if case .videoFrame(let frame) = message { sequences.append(frame.sequence) }
            }
            return sequences
        }
        try await withTimeout(.seconds(10)) {
            await merge.send(.videoFrame(videoFrame(5)), from: .lane(.video))
            await merge.send(.videoFrame(videoFrame(3)), from: .primary)     // stale: dropped, no suspension
            await merge.send(.videoFrame(videoFrame(6)), from: .primary)     // the flip
            await merge.send(.videoFrame(videoFrame(4)), from: .lane(.video)) // late straggler: dropped
            await merge.send(.videoFrame(videoFrame(7)), from: .lane(.video))
            merge.finish()
        }
        let delivered = await collector.value
        #expect(delivered == [5, 6, 7])
    }

    /// finish() releases a producer parked mid-hand-off (teardown must not strand forwarder
    /// tasks) and ends the consumer with nil.
    @Test func finishReleasesParkedSendersAndFinishesTheConsumer() async throws {
        let merge = LaneMerge()
        let sender = Task { await merge.send(.ping(Ping(sendMicros: 1)), from: .primary) }
        // Let the sender park (no consumer is pulling); either ordering is valid — finish
        // releases a parked sender, and a post-finish send returns immediately.
        try? await Task.sleep(for: .milliseconds(50))
        merge.finish()
        try await withTimeout(.seconds(10)) {
            await sender.value
            #expect(await merge.next() == nil)
        }
    }

    /// Cancelling the consuming task ends next() with nil (the app cancels its session task).
    @Test func consumerCancellationEndsNextWithNil() async throws {
        let merge = LaneMerge()
        let consumer = Task { await merge.next() }
        consumer.cancel()
        let value = try await withTimeout(.seconds(10)) { await consumer.value }
        #expect(value == nil)
    }
}

// MARK: - Loopback integration

/// Loopback integration for the CLIENT side of QUIC lane-splitting (bead w6n.5): a
/// `PortviewClientSession` against a multiplexed host — lanes open with the ServerHello token,
/// each lane's frames ride their own stream host-side, and everything merges back into the one
/// logical inbound stream (per-lane order preserved); plus the degradation paths (old flat host,
/// rejected lane binds, the lane→primary flip's stale-video drop).
@Suite struct LaneClientSessionLoopbackTests {
    @Test func mergedSessionStreamsLaneFramesIntoTheOneInboundStream() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let pin = try identity.certificateSHA256()
        let listener = try PortviewListener(quicIdentity: identity, multiplexed: true)
        let port = try await withTimeout(.seconds(20)) { try await listener.start() }
        let harness = LaneHostHarness()
        harness.serve(listener)

        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let session = try await PortviewClientSession.connectQUIC(to: endpoint, pinnedCertificateSHA256: pin)
        let collector = MergedCollector()
        _ = collector.collect(session.inbound)

        try await session.send(.clientHello(ClientHello(
            protocolVersion: ProtocolVersion.laneVersion, deviceID: "W6N5", deviceName: "MergeTest",
            codecs: [.hevc])))
        #expect(await poll { collector.firstServerHello != nil })
        let hello = try #require(collector.firstServerHello)
        let sessionToken = try #require(hello.sessionToken)
        // The tunnel-dialed session still resolves a concrete remote endpoint (the app's
        // saved-host refresh relies on it).
        #expect(session.resolvedRemoteEndpoint != nil)

        session.openLanes(sessionToken: sessionToken)
        session.openLanes(sessionToken: sessionToken) // idempotent: no duplicate opens
        #expect(await poll { harness.boundLaneSet == Set([.video, .audio, .stats]) })
        let videoLane = try #require(harness.lane(.video))
        let audioLane = try #require(harness.lane(.audio))
        let statsLane = try #require(harness.lane(.stats))

        // Two rounds of one frame per lane, paced by observation — every frame reaches the ONE
        // merged inbound stream, in per-lane order.
        try await videoLane.send(.videoFrame(videoFrame(1)))
        try await audioLane.send(.audioFrame(audioMarker(1)))
        try await statsLane.send(.qualityStats(statsMarker(1)))
        #expect(await poll {
            collector.videoSequences == [1] && collector.audioMarkers == [1] && collector.statsMarkers == [1]
        })
        try await videoLane.send(.videoFrame(videoFrame(2)))
        try await audioLane.send(.audioFrame(audioMarker(2)))
        try await statsLane.send(.qualityStats(statsMarker(2)))
        #expect(await poll {
            collector.videoSequences == [1, 2] && collector.audioMarkers == [1, 2] && collector.statsMarkers == [1, 2]
        })

        // Primary still flows alongside the lanes.
        try await session.send(.ping(Ping(sendMicros: 7)))
        #expect(await poll { collector.pongMarkers == [7] })
        #expect(harness.boundLaneSet.count == 3)

        // Teardown finishes the one merged stream.
        session.close()
        #expect(await poll { collector.isEnded })
        harness.cancel()
        listener.cancel()
    }

    /// Requirement (5): against an OLD host — flat listener, ServerHello at protocol v1, no
    /// sessionToken — the session behaves exactly as today: primary-only, no lane opens (the
    /// app's trigger is the token, and there is none), and a host-side close ends the inbound
    /// stream just like a bare connection's.
    @Test func oldFlatHostSessionStreamsOnPrimaryExactlyAsToday() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let pin = try identity.certificateSHA256()
        let listener = try PortviewListener(quicIdentity: identity) // flat delivery: today's host
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
                            try? await connection.send(.pong(Pong(sendMicros: ping.sendMicros, hostUptimeMicros: 0)))
                        case .bye:
                            connection.close()
                        default:
                            break
                        }
                    }
                }
            }
        }

        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let session = try await PortviewClientSession.connectQUIC(to: endpoint, pinnedCertificateSHA256: pin)
        let collector = MergedCollector()
        _ = collector.collect(session.inbound)

        try await session.send(.clientHello(ClientHello(
            protocolVersion: ProtocolVersion.current, deviceID: "OLD", deviceName: "Legacy",
            codecs: [.hevc])))
        #expect(await poll { collector.firstServerHello != nil })
        let hello = try #require(collector.firstServerHello)
        #expect(hello.sessionToken == nil)

        try await session.send(.ping(Ping(sendMicros: 3)))
        #expect(await poll { collector.pongMarkers == [3] })

        // Host closes the primary → the merged inbound finishes (streamSession's stream-ended
        // path works unchanged over the tunnel dial).
        try await session.send(.bye(Bye(reason: "test over")))
        #expect(await poll { collector.isEnded })

        serverTask.cancel()
        session.close()
        listener.cancel()
    }

    /// Requirement (3): lane-open failure degrades gracefully. The host advertises a token but
    /// never authorizes it (every lane bind is rejected and its stream closed) — the session
    /// keeps streaming on primary, and no lane traffic ever surfaces.
    @Test func rejectedLaneBindsLeaveTheSessionStreamingOnPrimary() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let pin = try identity.certificateSHA256()
        let listener = try PortviewListener(quicIdentity: identity, multiplexed: true)
        let port = try await withTimeout(.seconds(20)) { try await listener.start() }
        let harness = LaneHostHarness()
        harness.serve(listener, authorizeLanes: false)

        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let session = try await PortviewClientSession.connectQUIC(to: endpoint, pinnedCertificateSHA256: pin)
        let collector = MergedCollector()
        _ = collector.collect(session.inbound)

        try await session.send(.clientHello(ClientHello(
            protocolVersion: ProtocolVersion.laneVersion, deviceID: "FAIL", deviceName: "LaneFail",
            codecs: [.hevc])))
        #expect(await poll { collector.firstServerHello != nil })
        let sessionToken = try #require(collector.firstServerHello?.sessionToken)

        session.openLanes(sessionToken: sessionToken)
        // The rejected lane streams die host-side; the session must keep flowing on primary.
        try await session.send(.ping(Ping(sendMicros: 1)))
        #expect(await poll { collector.pongMarkers == [1] })
        try await session.send(.ping(Ping(sendMicros: 2)))
        #expect(await poll { collector.pongMarkers == [1, 2] })
        #expect(harness.boundLaneSet.isEmpty)
        #expect(collector.videoSequences.isEmpty)
        #expect(collector.audioMarkers.isEmpty)
        #expect(collector.statsMarkers.isEmpty)

        session.close()
        harness.cancel()
        listener.cancel()
    }

    /// Requirement (4): the lane→primary flip's ordering guard, over real streams. Frames 1–3
    /// ride the video lane, the "flip" moves 4–5 onto primary, then a late lane straggler
    /// (sequence 3 again) must be dropped at the merge while a genuinely newer lane frame (7)
    /// still gets through. Lane FIFO guarantees the straggler was processed before 7, so once 7
    /// is observed the transcript is final.
    @Test func staleVideoAcrossTheLaneFlipIsDroppedAtTheMergePoint() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let pin = try identity.certificateSHA256()
        let listener = try PortviewListener(quicIdentity: identity, multiplexed: true)
        let port = try await withTimeout(.seconds(20)) { try await listener.start() }
        let harness = LaneHostHarness()
        harness.serve(listener)

        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let session = try await PortviewClientSession.connectQUIC(to: endpoint, pinnedCertificateSHA256: pin)
        let collector = MergedCollector()
        _ = collector.collect(session.inbound)

        try await session.send(.clientHello(ClientHello(
            protocolVersion: ProtocolVersion.laneVersion, deviceID: "FLIP", deviceName: "FlipTest",
            codecs: [.hevc])))
        #expect(await poll { collector.firstServerHello != nil })
        let sessionToken = try #require(collector.firstServerHello?.sessionToken)
        session.openLanes(sessionToken: sessionToken)
        #expect(await poll { harness.boundLaneSet == Set([.video, .audio, .stats]) })
        let videoLane = try #require(harness.lane(.video))
        let primary = try #require(harness.primary)

        // One frame per step, paced by observation (a burst inside one receive callback could
        // legitimately coalesce in the bounded video buffer and muddy the assertion).
        for sequence: UInt64 in [1, 2, 3] {
            try await videoLane.send(.videoFrame(videoFrame(sequence)))
            #expect(await poll { collector.videoSequences.last == sequence })
        }
        // The flip: newer frames arrive on primary.
        for sequence: UInt64 in [4, 5] {
            try await primary.send(.videoFrame(videoFrame(sequence)))
            #expect(await poll { collector.videoSequences.last == sequence })
        }
        // Late lane straggler from before the flip: silently dropped at the merge point.
        try await videoLane.send(.videoFrame(videoFrame(3)))
        // A genuinely newer lane frame still gets through (and, by lane FIFO, proves the
        // straggler was already processed).
        try await videoLane.send(.videoFrame(videoFrame(7)))
        #expect(await poll { collector.videoSequences.last == 7 })
        #expect(collector.videoSequences == [1, 2, 3, 4, 5, 7])

        session.close()
        harness.cancel()
        listener.cancel()
    }
}

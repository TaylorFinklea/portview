// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import Network
@testable import PortviewHostCore
import PortviewTransport
import PortviewProtocol

// MARK: - Support (mirrors LaneTransportTests' loopback idiom)

private struct StreamClosedError: Error {}
private struct LoopbackTimeoutError: Error {}

/// Run `operation`, failing with `LoopbackTimeoutError` if it outlasts `duration`.
private func withTimeout<T: Sendable>(
    _ duration: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask { try await Task.sleep(for: duration); throw LoopbackTimeoutError() }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// Next inbound message on `connection`, bounded by `timeout`; throws if the stream finishes
/// (the peer closed that stream) before yielding one.
private func nextMessage(on connection: PortviewConnection,
                         timeout: Duration = .seconds(20)) async throws -> AnyMessage {
    try await withTimeout(timeout) {
        for await message in connection.inbound { return message }
        throw StreamClosedError()
    }
}

/// Poll `condition` every 10 ms until it holds or `deadline` elapses (QUIC handshakes and stream
/// opens take real time — deadlines are generous).
private func pollUntil(_ deadline: Duration = .seconds(20),
                       _ condition: @escaping @Sendable () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let end = clock.now.advanced(by: deadline)
    while clock.now < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private final class KeyframeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// Thread-safe view of the host side the serve task builds: the session's router and the
/// accepted lane connections as they bind.
private final class LaneHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var routerValue: HostLaneRouter?
    private var lanes: [Lane: PortviewConnection] = [:]
    func setRouter(_ router: HostLaneRouter) { lock.lock(); routerValue = router; lock.unlock() }
    var router: HostLaneRouter? { lock.lock(); defer { lock.unlock() }; return routerValue }
    func record(_ accepted: AcceptedLane) {
        lock.lock(); lanes[accepted.lane] = accepted.connection; lock.unlock()
    }
    func lane(_ lane: Lane) -> PortviewConnection? {
        lock.lock(); defer { lock.unlock() }; return lanes[lane]
    }
    var boundCount: Int { lock.lock(); defer { lock.unlock() }; return lanes.count }
}

private func videoMarker(_ n: UInt64) -> AnyMessage {
    .videoFrame(VideoFrame(sequence: n, ptsMicros: 0, isKeyframe: true,
                           displayID: 1, width: 8, height: 8, data: [0xAA]))
}
private func audioMarker(_ n: UInt64) -> AnyMessage {
    .audioFrame(AudioFrame(sampleRate: UInt32(n), channels: 1, ptsMicros: 0, data: [0xBB]))
}
private func statsMarker(_ n: UInt64) -> AnyMessage {
    .qualityStats(QualityStats(
        displayID: UInt32(n), encoderWidth: 0, encoderHeight: 0, configuredBitrate: 0,
        encodedMbpsX100: 0, fpsX100: 0, averageFrameBytes: 0, keyframes: 0,
        averageEncodeMsX100: 0, viewportX: 0, viewportY: 0, viewportW: 0, viewportH: 0))
}

/// Serve one router-wired host session per frame-path connection: on `ClientHello`, build the
/// session router, authorize lanes ONCE with `token` (binding each accepted lane into the router
/// as `serveSession` does), then reply with the token-carrying `ServerHello`.
private func serveRouterHost(_ listener: PortviewListener, token: [UInt8],
                             harness: LaneHarness) -> Task<Void, Never> {
    Task {
        for await connection in listener.connections {
            Task {
                for await message in connection.inbound {
                    guard case .clientHello = message else { continue }
                    let router = HostLaneRouter(primary: connection)
                    if let lanes = router.authorizeLanesOnce({ connection.acceptLanes(sessionToken: token) }) {
                        Task {
                            for await accepted in lanes {
                                harness.record(accepted)
                                router.bind(accepted.lane, accepted.connection)
                            }
                        }
                    }
                    harness.setRouter(router)
                    try? await connection.send(.serverHello(ServerHello(
                        protocolVersion: ProtocolVersion.laneVersion, displays: [],
                        chosenCodec: .hevc, sessionToken: token)))
                }
            }
        }
    }
}

// MARK: - Loopback integration

/// The host routing layer over a REAL tunnel (bead w6n.4), against the host's own multiplexed
/// listener construction (`HostRunner.startListener`): per-lane routing through
/// `HostLaneRouter`, then a lane death — the dead video lane flips to primary once, forcing an
/// encoder keyframe, without replaying the errored frame or touching the other lanes.
@Suite struct HostLaneRoutingLoopbackTests {
    @Test func routerRoutesPerLaneAndFlipsADeadVideoLaneToPrimaryWithForcedKeyframe() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let pin = try identity.certificateSHA256()
        // The host's listener path — multiplexed (grouped) delivery is enabled there (w6n.4).
        // No timeout wrapper needed (TLSIdentity isn't Sendable): start() resolves every state.
        let (listener, rawPort) = try await HostRunner.startListener(
            identity: identity, serviceName: "LaneRouterTest", preferredPort: nil)
        let port = try #require(NWEndpoint.Port(rawValue: rawPort))

        let token = LaneSessionToken.mint()
        let harness = LaneHarness()
        let serverTask = serveRouterHost(listener, token: token, harness: harness)

        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let tunnel = try await PortviewTunnel.connectQUIC(to: endpoint, pinnedCertificateSHA256: pin)
        let primary = try await tunnel.openPrimaryStream()
        try await primary.send(.clientHello(ClientHello(
            protocolVersion: ProtocolVersion.laneVersion, deviceID: "W6N4",
            deviceName: "RouterTest", codecs: [.hevc])))
        let helloReply = try await nextMessage(on: primary)
        guard case .serverHello(let hello) = helloReply, let sessionToken = hello.sessionToken else {
            Issue.record("expected a token-carrying ServerHello, got \(helloReply)")
            serverTask.cancel(); tunnel.cancel(); listener.cancel()
            return
        }

        let video = try await tunnel.openLane(.video, sessionToken: sessionToken)
        let audio = try await tunnel.openLane(.audio, sessionToken: sessionToken)
        let stats = try await tunnel.openLane(.stats, sessionToken: sessionToken)

        // All three lanes bound host-side; the bounded lane wait then resolves with them intact.
        #expect(await pollUntil { harness.boundCount == 3 })
        let router = try #require(harness.router)
        await router.awaitLaneBindings()
        let keyframes = KeyframeCounter()
        router.setKeyframeRequester { keyframes.increment() }

        // Per-lane routing: each marker arrives on ITS stream (type + marker prove the lane).
        try await router.send(videoMarker(1), lane: .video)
        try await router.send(audioMarker(1), lane: .audio)
        try await router.send(statsMarker(1), lane: .stats)
        #expect(try await nextMessage(on: video) == videoMarker(1))
        #expect(try await nextMessage(on: audio) == audioMarker(1))
        #expect(try await nextMessage(on: stats) == statsMarker(1))

        // Lane death: kill the video lane's host-side stream, so the router's next send fails
        // (the per-send health signal). The errored frame is absorbed — flip + forced keyframe —
        // and NOT replayed; the following frame rides primary.
        try #require(harness.lane(.video)).close()
        try await withTimeout(.seconds(20)) { try await router.send(videoMarker(2), lane: .video) }
        try await withTimeout(.seconds(20)) { try await router.send(videoMarker(3), lane: .video) }
        #expect(try await nextMessage(on: primary) == videoMarker(3))
        #expect(keyframes.count == 1)

        // The flip touched ONLY the video lane: stats still flow on their own stream.
        try await router.send(statsMarker(2), lane: .stats)
        #expect(try await nextMessage(on: stats) == statsMarker(2))

        serverTask.cancel()
        primary.close()
        tunnel.cancel()
        listener.cancel()
    }
}

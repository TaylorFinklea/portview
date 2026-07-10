// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import Network
@testable import PortviewHostCore
import PortviewTransport
import PortviewProtocol

// MARK: - Support

/// Records every message it was asked to send; optionally fails every send (a dead stream from
/// the router's point of view — the per-send health signal is the send error).
private final class RecordingSender: LaneStreamSender, @unchecked Sendable {
    struct SendFailure: Error {}
    private let lock = NSLock()
    private var messages: [AnyMessage] = []
    private let failing: Bool
    init(failing: Bool = false) { self.failing = failing }
    func send(_ message: AnyMessage) async throws {
        if failing { throw SendFailure() }
        record(message)
    }
    private func record(_ message: AnyMessage) {
        lock.lock(); messages.append(message); lock.unlock()
    }
    var sent: [AnyMessage] { lock.lock(); defer { lock.unlock() }; return messages }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// A router whose session authorized lanes (the lane-capable state serveSession reaches after a
/// lane-version handshake); unit tests bind fakes directly instead of consuming the stream.
private func laneCapableRouter(primary: any LaneStreamSender,
                               bindWait: Duration = .seconds(2)) -> HostLaneRouter {
    let router = HostLaneRouter(primary: primary, laneBindWait: bindWait)
    _ = router.authorizeLanesOnce { AsyncStream<AcceptedLane>.makeStream().stream }
    return router
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

// MARK: - Router unit tests (injectable seams)

@Suite struct HostLaneRouterTests {
    /// Old-version passthrough: a session that never authorized lanes routes EVERY send to
    /// primary, and the bounded lane wait is a structural no-op — exactly today's single-stream
    /// behavior. The huge bindWait proves the no-op: waiting it out would hang the test.
    @Test func legacySessionRoutesEverythingToPrimaryWithNoWait() async throws {
        let primary = RecordingSender()
        let router = HostLaneRouter(primary: primary, laneBindWait: .seconds(600))

        await router.awaitLaneBindings()

        try await router.send(videoMarker(1), lane: .video)
        try await router.send(audioMarker(2), lane: .audio)
        try await router.send(statsMarker(3), lane: .stats)
        #expect(primary.sent == [videoMarker(1), audioMarker(2), statsMarker(3)])
    }

    /// HARD invariant (w6n.3 review): lane authorization runs at most ONCE per primary
    /// connection — a repeat ClientHello must not re-authorize, because the transport's
    /// replace semantics would reset duplicate-lane protection.
    @Test func authorizeLanesOnceRefusesEveryCallAfterTheFirst() {
        let router = HostLaneRouter(primary: RecordingSender())
        let calls = Counter()

        let first = router.authorizeLanesOnce {
            calls.increment()
            return AsyncStream<AcceptedLane>.makeStream().stream
        }
        #expect(first != nil)
        #expect(calls.count == 1)

        let second = router.authorizeLanesOnce {
            calls.increment()
            return AsyncStream<AcceptedLane>.makeStream().stream
        }
        #expect(second == nil)
        #expect(calls.count == 1)
    }

    /// Bound lanes carry their own traffic; nothing leaks onto primary. With every routed lane
    /// already bound, the wait resolves immediately rather than sitting out its (huge, would
    /// hang the test) deadline.
    @Test func boundLanesCarryTheirOwnTraffic() async throws {
        let primary = RecordingSender()
        let router = laneCapableRouter(primary: primary, bindWait: .seconds(600))
        let video = RecordingSender()
        let audio = RecordingSender()
        let stats = RecordingSender()
        router.bind(.video, video)
        router.bind(.audio, audio)
        router.bind(.stats, stats)

        await router.awaitLaneBindings()

        try await router.send(videoMarker(1), lane: .video)
        try await router.send(audioMarker(2), lane: .audio)
        try await router.send(statsMarker(3), lane: .stats)
        #expect(video.sent == [videoMarker(1)])
        #expect(audio.sent == [audioMarker(2)])
        #expect(stats.sent == [statsMarker(3)])
        #expect(primary.sent.isEmpty)
    }

    /// Lane death: the first failed send flips the lane back to primary ONCE, forces exactly one
    /// encoder keyframe through the injected request path, does NOT replay the errored send, and
    /// refuses any later rebind (no reconnect).
    @Test func laneSendFailureFlipsToPrimaryOnceWithForcedKeyframeAndNoReplay() async throws {
        let primary = RecordingSender()
        let router = laneCapableRouter(primary: primary)
        router.bind(.video, RecordingSender(failing: true))
        let keyframes = Counter()
        router.setKeyframeRequester { keyframes.increment() }

        // The failed send is absorbed (never thrown to the caller) and never replayed.
        try await router.send(videoMarker(1), lane: .video)
        #expect(keyframes.count == 1)
        #expect(primary.sent.isEmpty)

        // Flipped: subsequent video sends ride primary; still exactly one forced keyframe.
        try await router.send(videoMarker(2), lane: .video)
        #expect(primary.sent == [videoMarker(2)])
        #expect(keyframes.count == 1)

        // A rebind after the flip is refused — the flip is one-way.
        let rebound = RecordingSender()
        router.bind(.video, rebound)
        try await router.send(videoMarker(3), lane: .video)
        #expect(rebound.sent.isEmpty)
        #expect(primary.sent == [videoMarker(2), videoMarker(3)])
    }

    /// The flip contract is one rule for every routed lane: a dying stats lane flips to primary
    /// (with the forced keyframe) without touching the other lanes' bindings.
    @Test func statsLaneFlipLeavesOtherLanesBound() async throws {
        let primary = RecordingSender()
        let router = laneCapableRouter(primary: primary)
        let video = RecordingSender()
        router.bind(.video, video)
        router.bind(.stats, RecordingSender(failing: true))
        let keyframes = Counter()
        router.setKeyframeRequester { keyframes.increment() }

        try await router.send(statsMarker(1), lane: .stats)
        #expect(keyframes.count == 1)
        try await router.send(statsMarker(2), lane: .stats)
        #expect(primary.sent == [statsMarker(2)])

        try await router.send(videoMarker(3), lane: .video)
        #expect(video.sent == [videoMarker(3)])
    }

    /// Primary-path send errors PROPAGATE: pumpVideo's catch (encoder rebuild + forced keyframe)
    /// keeps owning primary-stream recovery exactly as today.
    @Test func primarySendErrorsPropagateToTheCaller() async {
        let router = HostLaneRouter(primary: RecordingSender(failing: true))
        await #expect(throws: RecordingSender.SendFailure.self) {
            try await router.send(videoMarker(1), lane: .video)
        }
    }

    /// A lane-capable client that never opens its lane streams: the wait is bounded (the injected
    /// bindWait), after which every routed lane falls back to primary permanently — a late bind
    /// is ignored.
    @Test func neverOpeningClientFallsBackAfterBoundedWaitAndIgnoresLateBinds() async throws {
        let primary = RecordingSender()
        let router = laneCapableRouter(primary: primary, bindWait: .milliseconds(200))

        let clock = ContinuousClock()
        let start = clock.now
        await router.awaitLaneBindings()
        // The wait runs its full deadline (no lane ever binds); no upper-bound assert — wall
        // clock under full-suite parallelism is unbounded, the return itself is the bound.
        #expect(clock.now - start >= .milliseconds(200))

        try await router.send(videoMarker(1), lane: .video)
        #expect(primary.sent == [videoMarker(1)])

        // The fallback decision is permanent: a lane bound after resolution stays unused.
        let late = RecordingSender()
        router.bind(.video, late)
        try await router.send(videoMarker(2), lane: .video)
        #expect(late.sent.isEmpty)
        #expect(primary.sent == [videoMarker(1), videoMarker(2)])
    }

    /// The wait resolves as soon as all routed lanes bind, keeping the bindings intact — it does
    /// not sit out its deadline (huge here: waiting it out would hang the test) and does not
    /// mark mid-wait binds fallen-back.
    @Test func awaitLaneBindingsResolvesAsSoonAsAllLanesBind() async throws {
        let primary = RecordingSender()
        let router = laneCapableRouter(primary: primary, bindWait: .seconds(600))
        let video = RecordingSender()
        let binder = Task {
            try? await Task.sleep(for: .milliseconds(50))
            router.bind(.video, video)
            router.bind(.audio, RecordingSender())
            router.bind(.stats, RecordingSender())
        }
        defer { binder.cancel() }

        await router.awaitLaneBindings()

        // Resolution kept the bindings (nothing was marked fallen-back).
        try await router.send(videoMarker(1), lane: .video)
        #expect(video.sent == [videoMarker(1)])
        #expect(primary.sent.isEmpty)
    }
}

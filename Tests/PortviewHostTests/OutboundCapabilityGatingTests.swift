// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
@testable import PortviewHostCore
import PortviewTransport
import PortviewProtocol

// MARK: - Support (mirrors HostLaneRouterTests' RecordingSender, plus a `close()` observer)

/// Records every message it was asked to send, and every `close()` call — a scripted fake so
/// these tests never open a live socket.
private final class RecordingLaneSender: LaneStreamSender, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [AnyMessage] = []
    private var closeCount = 0
    func send(_ message: AnyMessage) async throws {
        record(message)
    }
    private func record(_ message: AnyMessage) {
        lock.lock(); messages.append(message); lock.unlock()
    }
    func close() {
        lock.lock(); closeCount += 1; lock.unlock()
    }
    var sent: [AnyMessage] { lock.lock(); defer { lock.unlock() }; return messages }
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return closeCount > 0 }
}

private func videoMarker(_ n: UInt64) -> AnyMessage {
    .videoFrame(VideoFrame(sequence: n, ptsMicros: 0, isKeyframe: true,
                           displayID: 1, width: 8, height: 8, data: [0xAA]))
}
private func statsMarker(_ n: UInt64) -> AnyMessage {
    .qualityStats(QualityStats(
        displayID: UInt32(n), encoderWidth: 0, encoderHeight: 0, configuredBitrate: 0,
        encodedMbpsX100: 0, fpsX100: 0, averageFrameBytes: 0, keyframes: 0,
        averageEncodeMsX100: 0, viewportX: 0, viewportY: 0, viewportW: 0, viewportH: 0))
}

/// The outbound half of han.4's capability boundary (design §2/§4 finding 4/H-e, Task 6): bringing
/// `pumpVideo`/`HostLaneRouter`/`OutboundLane` inside the capability so a revoked peer stops
/// RECEIVING immediately, not just stops being able to act. `HostLaneRouter.send` is the exact
/// choke point `pumpVideo`'s video/audio/stats sends all funnel through, so gating it here is
/// equivalent to gating each producer directly — `pumpVideo` itself needs a live
/// `ScreenCaptureKit` capture and is exercised only device-gated (§8).
@Suite struct OutboundCapabilityGatingTests {
    // MARK: HostLaneRouter.send

    @Test func routerSendDropsOnPrimaryWhenCapabilityIsInvalid() async throws {
        let primary = RecordingLaneSender()
        let capability = SessionCapability()
        let router = HostLaneRouter(primary: primary, capability: capability)
        capability.invalidate()

        try await router.send(videoMarker(1), lane: .video)

        #expect(primary.sent.isEmpty)
    }

    @Test func routerSendDropsOnABoundLaneWhenCapabilityIsInvalid() async throws {
        let primary = RecordingLaneSender()
        let capability = SessionCapability()
        let router = HostLaneRouter(primary: primary, capability: capability)
        _ = router.authorizeLanesOnce { AsyncStream<AcceptedLane>.makeStream().stream }
        let video = RecordingLaneSender()
        router.bind(.video, video)
        capability.invalidate()

        try await router.send(videoMarker(1), lane: .video)

        #expect(video.sent.isEmpty)
        #expect(primary.sent.isEmpty)
    }

    // MARK: OutboundLane production sink (finding 4's CursorReportPump residual)

    /// Pins the exact residual finding 4 names: a message already TAKEN from `OutboundLane`'s
    /// internal queue (i.e. already past `enqueue`, in the drain's hands) is still dropped if the
    /// capability flips invalid before the sink's `connection.send` actually runs. **Defined
    /// residual out of scope to recall (design §4):** bytes already handed to
    /// `Network.framework` for an in-flight `send()` — this test only exercises the pre-send gate,
    /// never a message that already reached the wire.
    @Test func productionSinkDropsATakenButUnsentMessageAfterInvalidate() async {
        let capability = SessionCapability()
        let sender = RecordingLaneSender()
        let lane = OutboundLane<AnyMessage>(connection: sender, capability: capability)

        lane.enqueue(.clipboardUpdate(ClipboardUpdate(text: "should-not-reach-the-sender")))
        capability.invalidate()

        // The drain task's `take()` → sink hop is unsynchronized with this test; poll rather than
        // assume a fixed delay drains it (this is an ABSENCE assertion, so a slow drain can only
        // false-fail, never false-pass, if we polled too briefly — the bound below is generous).
        for _ in 0..<200 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(sender.sent.isEmpty)
        lane.finish()
    }

    @Test func productionSinkSendsNormallyWhileCapabilityIsValid() async {
        let capability = SessionCapability()
        let sender = RecordingLaneSender()
        let lane = OutboundLane<AnyMessage>(connection: sender, capability: capability)

        lane.enqueue(.clipboardUpdate(ClipboardUpdate(text: "delivered")))
        for _ in 0..<500 {
            if !sender.sent.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(sender.sent == [.clipboardUpdate(ClipboardUpdate(text: "delivered"))])
        lane.finish()
    }

    // MARK: HostLaneRouter.closeBoundLanes

    @Test func closeBoundLanesClosesBoundSecondarySendersAndRefusesALateBind() async throws {
        let primary = RecordingLaneSender()
        let capability = SessionCapability()
        let router = HostLaneRouter(primary: primary, capability: capability)
        _ = router.authorizeLanesOnce { AsyncStream<AcceptedLane>.makeStream().stream }
        let video = RecordingLaneSender()
        let audio = RecordingLaneSender()
        router.bind(.video, video)
        router.bind(.audio, audio)

        router.closeBoundLanes()

        #expect(video.closed)
        #expect(audio.closed)

        // A bind racing (or arriving after) closure is REFUSED — today `bind` only guarded
        // `resolved`/`fallenBack`; a late bind after `closeBoundLanes` must not rewire a sender
        // into a router that already tore its lanes down.
        let late = RecordingLaneSender()
        router.bind(.stats, late)
        try await router.send(statsMarker(1), lane: .stats)
        #expect(late.sent.isEmpty)
        #expect(primary.sent == [statsMarker(1)])
        #expect(!late.closed)  // never wired in, so closeBoundLanes never gets a chance to close it
    }
}

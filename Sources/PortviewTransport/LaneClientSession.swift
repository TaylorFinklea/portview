import Foundation
import Network
import PortviewProtocol

// Client side of QUIC lane-splitting (spec: docs/superpowers/specs/2026-07-01-quic-lane-splitting.md,
// "Per-stream decode & merge"): one `PortviewTunnel` carries the primary stream plus the three
// phase-1 secondary lane streams (video/audio/stats), and `PortviewClientSession` merges every
// stream's decoded messages back into the ONE logical inbound `AsyncStream<AnyMessage>` the app
// already consumes. Each stream keeps its own `FrameDecoder` inside its `PortviewConnection`
// (frames never straddle streams — see `LanePreamble`); per-lane order is preserved (QUIC stream
// ordering plus one sequential forwarder per stream); cross-lane arrival order stays unordered,
// exactly the contract the app already has (a `VideoFrame` carries its own viewport) — except for
// the lane→primary video flip, which `StaleVideoGuard` covers at the merge point.

/// Which stream a merged message rode — the identity `StaleVideoGuard`'s per-stream ordering
/// rule compares.
enum MergeSource: Equatable, Sendable {
    case primary
    case lane(Lane)
}

/// Merge-point ordering guard for video across a lane flip. When the host's video lane dies it
/// flips video sends back to the primary stream, and frames already in flight on the
/// not-quite-dead lane can arrive AFTER newer primary-path frames (streams are independently
/// ordered). Host-side, `VideoFrame.sequence` is monotonic within one capture pump
/// (`HostRunner.pumpVideo` increments a local counter) but RESETS when the pump restarts
/// (display switch cancels and relaunches it), so a plain "highest sequence wins" filter would
/// blackhole every frame after a restart. The rule instead leans on per-stream ordering:
///
/// - A frame from the SAME source as the last accepted one is always current — its stream
///   delivers in order, so a sequence drop there is a legitimate pump restart, not staleness.
/// - A frame from a DIFFERENT source must be newer on AT LEAST ONE axis — sequence, or capture
///   PTS (`ptsMicros` rides the host clock, monotonic ACROSS pump restarts) — otherwise it is a
///   stale straggler from before the flip (or a cross-stream duplicate) and is dropped. The PTS
///   axis is what makes the guard recoverable when a pump restart lands INSIDE the flip window:
///   sequence resets there, and a sequence-only rule would drop every post-restart frame until
///   the new counter climbed past the old high-water (a video freeze with live audio).
struct StaleVideoGuard {
    private var lastSource: MergeSource?
    private var lastSequence: UInt64 = 0
    private var lastPtsMicros: UInt64 = 0

    /// True when `frame` is current (deliver it); false when it is a stale straggler (drop it).
    mutating func admit(_ frame: VideoFrame, from source: MergeSource) -> Bool {
        if let lastSource, source != lastSource,
           frame.sequence <= lastSequence, frame.ptsMicros <= lastPtsMicros {
            return false
        }
        lastSource = source
        lastSequence = frame.sequence
        lastPtsMicros = frame.ptsMicros
        return true
    }
}

/// Rendezvous hand-off merging several producers into ONE consumer without adding buffering: a
/// producer suspends in `send` until the consumer takes its message, so the only inbound
/// buffering remains each stream's own bounded `InboundBuffer` (whose high-water backpressure
/// pauses that stream's receive loop when the merge isn't being drained) — the merge does not
/// widen the bounded-buffer surface. Per-producer FIFO holds because each producer is one
/// sequential forwarder; cross-producer delivery is hand-off order (unordered, matching the
/// wire). The `StaleVideoGuard` runs inside the hand-off lock, so admit order IS delivery order
/// — a stale-vs-fresh race between two forwarders can't invert past the guard.
final class LaneMerge: @unchecked Sendable {
    /// One suspended `send`. `@unchecked Sendable`: fields are only touched under the owning
    /// merge's lock.
    private final class ParkedSend: @unchecked Sendable {
        let message: AnyMessage
        var continuation: CheckedContinuation<Void, Never>?
        var cancelled = false
        init(message: AnyMessage) { self.message = message }
    }

    private let lock = NSLock()
    private var finished = false
    private var videoGuard = StaleVideoGuard()
    private var parked: [ParkedSend] = []
    private var consumer: CheckedContinuation<AnyMessage?, Never>?

    /// Hand `message` (which rode `source`) to the consumer, suspending until it is taken. A
    /// stale video frame is dropped without suspending. Returns immediately once the merge is
    /// finished or the sending task is cancelled (both only happen at session teardown; the
    /// message is dropped).
    func send(_ message: AnyMessage, from source: MergeSource) async {
        let box = ParkedSend(message: message)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                var handoff: CheckedContinuation<AnyMessage?, Never>?
                var resumeImmediately = false
                lock.lock()
                if finished || box.cancelled {
                    resumeImmediately = true
                } else if case .videoFrame(let frame) = message, !videoGuard.admit(frame, from: source) {
                    resumeImmediately = true // stale straggler across the lane→primary flip
                } else if let waiting = consumer {
                    consumer = nil
                    handoff = waiting
                    resumeImmediately = true
                } else {
                    box.continuation = continuation
                    parked.append(box)
                }
                lock.unlock()
                handoff?.resume(returning: message)
                if resumeImmediately { continuation.resume() }
            }
        } onCancel: {
            lock.lock()
            box.cancelled = true
            if let index = parked.firstIndex(where: { $0 === box }) { parked.remove(at: index) }
            let taken = box.continuation
            box.continuation = nil
            lock.unlock()
            taken?.resume()
        }
    }

    /// Next merged message: takes the oldest parked hand-off first; suspends when none; nil once
    /// `finish()`ed and drained (or when the awaiting task is cancelled).
    func next() async -> AnyMessage? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<AnyMessage?, Never>) in
                var sender: CheckedContinuation<Void, Never>?
                var result: AnyMessage??
                lock.lock()
                if !parked.isEmpty {
                    let head = parked.removeFirst()
                    sender = head.continuation
                    head.continuation = nil
                    result = head.message
                } else if finished || Task.isCancelled {
                    result = AnyMessage?.none
                } else {
                    consumer = continuation
                }
                lock.unlock()
                sender?.resume()
                if let value = result { continuation.resume(returning: value) }
            }
        } onCancel: {
            lock.lock()
            let taken = consumer
            consumer = nil
            lock.unlock()
            taken?.resume(returning: nil)
        }
    }

    /// No more messages: release every suspended producer (their messages are dropped — only
    /// teardown and primary-stream death finish the merge) and wake the consumer with nil.
    func finish() {
        lock.lock()
        finished = true
        let senders = parked.compactMap { box -> CheckedContinuation<Void, Never>? in
            let taken = box.continuation
            box.continuation = nil
            return taken
        }
        parked.removeAll()
        let waiting = consumer
        consumer = nil
        lock.unlock()
        for sender in senders { sender.resume() }
        waiting?.resume(returning: nil)
    }
}

/// One client session over a lane-splitting QUIC tunnel: the primary stream (the existing
/// single-stream protocol — handshake, control, input, clipboard, files) plus, once the host
/// advertises a session token, the three secondary lane streams. Presents the same surface the
/// app consumed on a bare `PortviewConnection` — one merged inbound `AsyncStream<AnyMessage>`,
/// sends on primary, one `close()` — so `streamSession`'s consumers don't change.
public final class PortviewClientSession: @unchecked Sendable {
    /// Messages from every stream, merged into the one logical inbound stream the app consumes.
    /// Finishes when the PRIMARY stream ends; a lane ending just stops contributing — the
    /// session survives on primary (the host flips a dead lane's traffic back there after its
    /// bounded fallback wait).
    public let inbound: AsyncStream<AnyMessage>

    /// The three phase-1 secondary lanes (spec "Stream topology").
    static let secondaryLanes: [Lane] = [.video, .audio, .stats]

    private let tunnel: PortviewTunnel
    private let primary: PortviewConnection
    private let merge: LaneMerge
    private let lock = NSLock()
    private var lanesOpened = false

    /// Dial one QUIC tunnel to `endpoint` (pinned to `pinnedCertificateSHA256`) and open the
    /// primary stream on it. Works against BOTH host generations: a multiplexed host receives
    /// the tunnel as a group; an old flat host receives the primary stream via its existing
    /// accept path unchanged (Phase 0 spike, Q1). No lane is opened until `openLanes`.
    public static func connectQUIC(to endpoint: NWEndpoint, pinnedCertificateSHA256: Data) async throws -> PortviewClientSession {
        let tunnel = try await PortviewTunnel.connectQUIC(to: endpoint, pinnedCertificateSHA256: pinnedCertificateSHA256)
        do {
            let primary = try await tunnel.openPrimaryStream()
            return PortviewClientSession(tunnel: tunnel, primary: primary)
        } catch {
            tunnel.cancel()
            throw error
        }
    }

    init(tunnel: PortviewTunnel, primary: PortviewConnection) {
        self.tunnel = tunnel
        self.primary = primary
        let merge = LaneMerge()
        self.merge = merge
        self.inbound = AsyncStream(unfolding: { await merge.next() })
        forward(primary, as: .primary)
    }

    /// Open the three secondary lane streams with the host-minted `sessionToken` from
    /// `ServerHello` (present iff the hello's `protocolVersion >= ProtocolVersion.laneVersion`
    /// — the codec makes token presence and lane support the same signal, so an old host never
    /// gets a lane open attempted). Fire-and-forget and failure-tolerant by design: each lane
    /// opens independently and writes only its `LanePreamble` (then stays quiet); any failure —
    /// open error, rejected bind, lane death — leaves the session streaming on primary, which
    /// the host's bounded fallback covers. Idempotent: only the first call opens lanes.
    public func openLanes(sessionToken: [UInt8]) {
        lock.lock()
        let firstCall = !lanesOpened
        lanesOpened = true
        lock.unlock()
        guard firstCall else { return }
        for lane in Self.secondaryLanes {
            Task { [weak self, tunnel] in
                guard let connection = try? await tunnel.openLane(lane, sessionToken: sessionToken) else {
                    return // lane-open failure: the session continues on primary
                }
                guard let self else {
                    connection.close() // session already torn down
                    return
                }
                self.forward(connection, as: .lane(lane))
            }
        }
    }

    /// Send on the primary stream. The client sends no frames on secondary lanes (their send
    /// side carries only the one-time `LanePreamble`).
    public func send(_ message: AnyMessage) async throws {
        try await primary.send(message)
    }

    /// The primary stream's resolved remote endpoint (see
    /// `PortviewConnection.resolvedRemoteEndpoint`).
    public var resolvedRemoteEndpoint: NWEndpoint? { primary.resolvedRemoteEndpoint }

    /// Tear the whole session down: cancel the tunnel (and with it every lane stream), close
    /// the primary stream, and finish the merged stream (releasing any forwarder parked
    /// mid-hand-off).
    public func close() {
        tunnel.cancel()
        primary.close()
        merge.finish()
    }

    /// Pump one stream's decoded messages into the merge, tagged with the stream they rode.
    /// Ends when that stream's inbound finishes; only the PRIMARY stream's end finishes the
    /// merged stream — a dead lane just stops contributing. Captures the merge, not `self`, so
    /// forwarders never keep a dropped session alive.
    private func forward(_ connection: PortviewConnection, as source: MergeSource) {
        let merge = self.merge
        Task {
            for await message in connection.inbound {
                await merge.send(message, from: source)
            }
            if source == .primary { merge.finish() }
        }
    }
}

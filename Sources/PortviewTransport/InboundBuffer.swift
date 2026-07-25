// SPDX-License-Identifier: Apache-2.0
import Foundation
import PortviewProtocol

/// Two-lane inbound message buffer giving the connection real backpressure without changing the
/// `AsyncStream<AnyMessage>` surface consumers iterate (`PortviewConnection.inbound` is built with
/// `AsyncStream(unfolding:)` pulling from here).
///
/// Lanes:
/// - **Control** (everything but audio/video): lossless FIFO. Its buffered payload bytes are metered
///   against a high/low water mark — crossing the high water tells the connection to STOP
///   re-arming `receive`, so the transport's own flow control (QUIC receive window) pushes back
///   on the peer; draining below the low water resumes it (hysteresis, no thrash).
/// - **Audio**: coalesces to the newest packets. Audio is realtime media, not control: placing it
///   in the lossless control FIFO lets a steady audio stream starve video forever.
/// - **Video**: coalesces to the newest `videoLaneDepth` frames (mirrors CaptureEngine's
///   `.bufferingNewest(2)`) — a stalled consumer costs at most two frames of memory. The newest
///   KEYFRAME is pinned against eviction (the decoder's only resync point — see
///   `KeyframeRecovery`, which requests one whenever a coalesced-away delta breaks the HEVC
///   reference chain). When both realtime lanes have data they alternate, while control remains
///   latency-priority.
///
/// Lock-guarded (the repo's transport/host idiom) because producers arrive on the connection's
/// DispatchQueue while the consumer suspends in Swift Concurrency.
final class InboundBuffer: @unchecked Sendable {
    static let defaultVideoLaneDepth = 2
    static let defaultAudioLaneDepth = 8
    static let defaultControlHighWaterBytes = 4 * 1024 * 1024
    static let defaultControlLowWaterBytes = 1 * 1024 * 1024

    private let lock = NSLock()
    private var controlLane: [AnyMessage] = []
    private var controlHead = 0 // popped index — avoids O(n) removeFirst per message
    private var audioLane: [AnyMessage] = []
    private var videoLane: [AnyMessage] = []
    /// Alternates realtime delivery whenever both audio and video have work, so neither stream
    /// can starve the other. The first tie favors audio to keep scheduling its playout buffer warm.
    private var deliverAudioNext = true
    private var waiter: CheckedContinuation<AnyMessage?, Never>?
    private var finished = false
    private(set) var controlBytesBuffered = 0
    private(set) var droppedAudioFrames = 0
    private(set) var droppedVideoFrames = 0
    /// True while the connection should NOT re-arm `receive` (control lane above high water).
    private(set) var isReceivePaused = false

    private let videoLaneDepth: Int
    private let audioLaneDepth: Int
    private let controlHighWaterBytes: Int
    private let controlLowWaterBytes: Int
    private var onResumeReceive: @Sendable () -> Void

    /// The connection sets this after init (it captures the connection itself); guarded by the
    /// same lock as the buffer state so later reads on the receive path are race-free.
    func setOnResumeReceive(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        onResumeReceive = handler
        lock.unlock()
    }

    var videoFramesBuffered: Int { lock.lock(); defer { lock.unlock() }; return videoLane.count }
    var audioFramesBuffered: Int { lock.lock(); defer { lock.unlock() }; return audioLane.count }

    init(videoLaneDepth: Int = InboundBuffer.defaultVideoLaneDepth,
         audioLaneDepth: Int = InboundBuffer.defaultAudioLaneDepth,
         controlHighWaterBytes: Int = InboundBuffer.defaultControlHighWaterBytes,
         controlLowWaterBytes: Int = InboundBuffer.defaultControlLowWaterBytes,
         onResumeReceive: @escaping @Sendable () -> Void = {}) {
        self.videoLaneDepth = videoLaneDepth
        self.audioLaneDepth = audioLaneDepth
        self.controlHighWaterBytes = controlHighWaterBytes
        self.controlLowWaterBytes = controlLowWaterBytes
        self.onResumeReceive = onResumeReceive
    }

    /// Terminal verdict for `enqueue` — `.droppedFinished` once the buffer is finished (whether by
    /// `finish()` or `finishDiscardingBuffered()`), so a receive callback racing a discard-close
    /// can never re-add a message nor re-arm the receive loop (han.4 finding 7).
    enum EnqueueOutcome: Equatable, Sendable {
        /// The messages were appended. `pauseReceive` is true when the control lane crossed its
        /// high water — the caller must stop re-arming `receive` until `onResumeReceive` fires.
        case accepted(pauseReceive: Bool)
        /// The buffer is already finished; nothing was appended.
        case droppedFinished
    }

    /// Add decoded messages, unless the buffer is already finished. See `EnqueueOutcome`.
    @discardableResult
    func enqueue(_ messages: [AnyMessage]) -> EnqueueOutcome {
        var handoff: (CheckedContinuation<AnyMessage?, Never>, AnyMessage)?
        var fireResume = false
        lock.lock()
        guard !finished else {
            lock.unlock()
            return .droppedFinished
        }
        for message in messages {
            if case .videoFrame = message {
                videoLane.append(message)
                // Newest-wins, except the newest KEYFRAME is pinned against eviction: it is the
                // decoder's only resync point, and the recovery IDR the client just requested
                // must not be coalesced away by the very burst it recovers from (2026-07-16
                // freeze). Deltas around it stay newest-wins; a newer keyframe supersedes the pin.
                while videoLane.count > videoLaneDepth {
                    let evictIndex = newestKeyframeIndexLocked() == 0 ? 1 : 0
                    videoLane.remove(at: evictIndex)
                    droppedVideoFrames += 1
                }
            } else if case .audioFrame = message {
                audioLane.append(message)
                let overflow = audioLane.count - audioLaneDepth
                if overflow > 0 {
                    audioLane.removeFirst(overflow)
                    droppedAudioFrames += overflow
                }
            } else {
                controlLane.append(message)
                controlBytesBuffered += Self.approximatePayloadBytes(message)
            }
        }
        if controlBytesBuffered > controlHighWaterBytes { isReceivePaused = true }
        if let continuation = waiter, let next = dequeueLocked() {
            waiter = nil
            handoff = (continuation, next)
            // The handoff drained bytes — a kept-up consumer must not strand receive paused
            // with an empty buffer (no future next() would ever fire the resume).
            fireResume = maybeClearPauseLocked()
        }
        let paused = isReceivePaused
        let resumeHandler: (@Sendable () -> Void)? = fireResume ? onResumeReceive : nil
        lock.unlock()
        if let (continuation, message) = handoff { continuation.resume(returning: message) }
        resumeHandler?()
        return .accepted(pauseReceive: paused)
    }

    /// Next message: queued control first, then alternating buffered audio/video; suspends when
    /// empty; nil once `finish()`ed and drained (or when the awaiting task is cancelled).
    func next() async -> AnyMessage? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<AnyMessage?, Never>) in
                var resumeNow: AnyMessage??
                var resumeHandler: (@Sendable () -> Void)?
                lock.lock()
                if let message = dequeueLocked() {
                    if maybeClearPauseLocked() { resumeHandler = onResumeReceive }
                    resumeNow = message
                } else if finished || Task.isCancelled {
                    resumeNow = AnyMessage?.none
                } else {
                    waiter = continuation
                }
                lock.unlock()
                resumeHandler?()
                if let value = resumeNow { continuation.resume(returning: value) }
            }
        } onCancel: {
            lock.lock()
            let continuation = takeWaiterLocked()
            lock.unlock()
            continuation?.resume(returning: nil)
        }
    }

    /// No more messages will arrive: wake any suspended consumer; remaining buffered messages
    /// still drain, then `next()` returns nil forever.
    func finish() {
        lock.lock()
        finished = true
        var handoff: (CheckedContinuation<AnyMessage?, Never>, AnyMessage?)?
        if let continuation = takeWaiterLocked() {
            handoff = (continuation, dequeueLocked()) // drain-then-nil: hand a parked waiter the head
        }
        lock.unlock()
        if let (continuation, value) = handoff { continuation.resume(returning: value) }
    }

    /// No more messages will arrive AND every already-buffered message is DISCARDED, not drained —
    /// the security-critical contrast to `finish()` (han.4 finding 7): a revoked peer's queued
    /// keyboard/clipboard/file frames must never be delivered. Clears all three lanes under the
    /// lock before marking finished, so a parked `next()` resumes nil and every future `next()`
    /// returns nil immediately; a racing `enqueue` is linearized by the same lock — it either
    /// completes fully before this (and is cleared here) or fully after (and sees `finished` →
    /// `.droppedFinished`).
    func finishDiscardingBuffered() {
        lock.lock()
        controlLane.removeAll(keepingCapacity: false)
        controlHead = 0
        controlBytesBuffered = 0
        audioLane.removeAll(keepingCapacity: false)
        videoLane.removeAll(keepingCapacity: false)
        finished = true
        let continuation = takeWaiterLocked()
        lock.unlock()
        continuation?.resume(returning: nil)
    }

    // MARK: - Locked helpers (call only while holding `lock`)

    private func dequeueLocked() -> AnyMessage? {
        if controlHead < controlLane.count {
            let message = controlLane[controlHead]
            controlHead += 1
            controlBytesBuffered -= Self.approximatePayloadBytes(message)
            if controlHead == controlLane.count { controlLane.removeAll(keepingCapacity: true); controlHead = 0 }
            return message
        }
        if !audioLane.isEmpty, !videoLane.isEmpty {
            if deliverAudioNext {
                deliverAudioNext = false
                return audioLane.removeFirst()
            }
            deliverAudioNext = true
            return videoLane.removeFirst()
        }
        if !audioLane.isEmpty {
            deliverAudioNext = false
            return audioLane.removeFirst()
        }
        if !videoLane.isEmpty {
            deliverAudioNext = true
            return videoLane.removeFirst()
        }
        return nil
    }

    /// Index of the newest keyframe in the video lane, or nil when none is buffered.
    private func newestKeyframeIndexLocked() -> Int? {
        videoLane.lastIndex { message in
            if case .videoFrame(let frame) = message { return frame.isKeyframe }
            return false
        }
    }

    private func maybeClearPauseLocked() -> Bool {
        guard isReceivePaused, controlBytesBuffered < controlLowWaterBytes else { return false }
        isReceivePaused = false
        return true
    }

    private func takeWaiterLocked() -> CheckedContinuation<AnyMessage?, Never>? {
        let taken = waiter
        waiter = nil
        return taken
    }

    /// Meter only payload-bearing control messages (a fixed overhead per message plus the big
    /// variable payloads); realtime audio and video are bounded by lane depth, not bytes.
    private static func approximatePayloadBytes(_ message: AnyMessage) -> Int {
        let payload: Int = switch message {
        case .fileChunk(let m): m.data.count
        case .clipboardUpdate(let m): m.text.utf8.count
        case .typeText(let m): m.text.utf8.count
        default: 0
        }
        return 64 + payload
    }
}

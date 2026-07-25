// SPDX-License-Identifier: Apache-2.0
import Foundation
import PortviewProtocol
import PortviewTransport

/// One ordered outbound lane per owner: a single drain Task awaits each sink call in turn, so
/// everything enqueued is delivered in enqueue order — replacing the fire-and-forget `Task { send }`
/// pattern whose sends could complete out of order under load and which nothing tied to session
/// teardown. The session's lane is owned by `serveSession` and `finish()`ed in its `defer`; after
/// `finish()` pending messages are dropped and later enqueues are ignored. An enqueue with a
/// `CoalesceKey` replaces a pending same-key entry (latest payload, earliest queue position) —
/// exact for absolute-value messages like cursor position, where intermediate samples are
/// redundant.
final class OutboundLane<Message: Sendable>: @unchecked Sendable {
    /// Message kinds that may coalesce: a pending entry with the same key is replaced instead of
    /// appended.
    enum CoalesceKey: Hashable {
        case cursorPosition
    }

    private let lock = NSLock()
    // `completion` is non-nil only for `send(_:)` entries (always keyless), resumed after the sink
    // ran — or at `finish()`, so an awaiting sender can never hang on a torn-down lane. Coalescing
    // replacement never has to resume one: keyed entries come only from `enqueue`.
    private var queue: [(key: CoalesceKey?, message: Message, completion: CheckedContinuation<Void, Never>?)] = []
    private var finished = false
    private let wakeContinuation: AsyncStream<Void>.Continuation
    private var task: Task<Void, Never>?

    /// Drain into an injected async sink — a live connection in production, a recorder in tests.
    init(sink: @escaping @Sendable (Message) async -> Void) {
        // `.unbounded` is load-bearing: every enqueue must deliver a wake so a message can't be
        // stranded in the queue. (Coalescing sheds redundant samples via key replacement, not by
        // dropping wakes.)
        let (wake, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
        self.wakeContinuation = continuation
        self.task = nil // satisfy definite-init before capturing self below
        self.task = Task { [weak self] in
            for await _ in wake {
                while let next = self?.take() {
                    await sink(next.message)
                    next.completion?.resume()
                }
            }
        }
    }

    /// Enqueue for ordered delivery. Safe to call from any context. With a `coalescing` key, a
    /// pending same-key entry is replaced (last-wins) instead of growing the queue. No-op once
    /// `finish()` has run — nothing is delivered after teardown.
    func enqueue(_ message: Message, coalescing key: CoalesceKey? = nil) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if let key, let index = queue.firstIndex(where: { $0.key == key }) {
            queue[index].message = message
        } else {
            queue.append((key, message, nil))
        }
        lock.unlock()
        wakeContinuation.yield(())
    }

    /// Enqueue and suspend until the sink has run for this message (or the lane finished) — the
    /// back-pressure primitive for bulk traffic: a file transfer awaits each chunk so at most one
    /// sits in the queue, and control messages (lock status, clipboard, cursor) never wait behind
    /// more than one chunk. Returns immediately if the lane is already finished.
    func send(_ message: Message) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            guard !finished else {
                lock.unlock()
                continuation.resume()
                return
            }
            queue.append((nil, message, continuation))
            lock.unlock()
            wakeContinuation.yield(())
        }
    }

    /// Stop delivery: pending messages are dropped (their awaiting senders resumed) and later
    /// enqueues are ignored. Idempotent and safe against a concurrent caller — all state swaps
    /// happen under the lock. Called from the owning session's teardown `defer`.
    func finish() {
        lock.lock()
        finished = true
        let dropped = queue
        queue.removeAll()
        let drain = task
        task = nil
        lock.unlock()
        for entry in dropped { entry.completion?.resume() }
        wakeContinuation.finish()
        drain?.cancel()
    }

    private func take() -> (message: Message, completion: CheckedContinuation<Void, Never>?)? {
        lock.lock()
        defer { lock.unlock() }
        guard !queue.isEmpty else { return nil }
        let entry = queue.removeFirst()
        return (entry.message, entry.completion)
    }
}

extension OutboundLane where Message == AnyMessage {
    /// Production: drain into a live connection, capability-gated (han.4 Task 6, design §2/§4
    /// finding 4/H-e). The gate re-checks `capability.isValid` HERE, inside the sink — i.e. after
    /// `take()` has already removed the message from the queue — so a message accepted while the
    /// capability was still valid is dropped if it flipped invalid before this sink actually ran.
    /// Takes `any LaneStreamSender` (not the concrete `PortviewConnection`) so tests can gate a
    /// scripted fake instead of opening a live socket.
    convenience init(connection: any LaneStreamSender, capability: SessionCapability) {
        self.init(sink: { message in
            guard capability.isValid else { return }
            try? await connection.send(message)
        })
    }
}

/// Cursor-position reporting as a thin facade over `OutboundLane` — the return-path analogue of the
/// client's `OutboundInputPump`. Confirmations reach the client in monotonic order (the prior
/// detached-Task-per-report design could complete out of order under load and back-step the
/// client's cursor-follow), and a pending report coalesces to the latest position — the cursor is
/// absolute, so last-wins is exact and the client is predicting locally anyway.
final class CursorReportPump: @unchecked Sendable {
    private let submit: (Double, Double) -> Void
    private let teardown: () -> Void

    /// Production: report through the session's shared lane, so cursor confirmations order with the
    /// session's other outbound messages and tear down with the lane's owner. (The wire type
    /// quantizes to UInt16 — fine here, positions are already normalized 0…1.) `finish()` is a
    /// deliberate no-op in this mode: the pump does not own the shared lane, and finishing it here
    /// would silently kill the session's clipboard/broadcast/file sends — serveSession's defer owns
    /// that teardown.
    init(lane: OutboundLane<AnyMessage>) {
        submit = { nx, ny in
            lane.enqueue(.cursorPosition(CursorPosition(normalizedX: nx, normalizedY: ny)),
                         coalescing: .cursorPosition)
        }
        teardown = {}
    }

    /// Test seam: a private lane draining raw values into an injected sink — deliberately NOT
    /// routed through the `CursorPosition` wire type, whose 0…1 clamp + UInt16 quantization would
    /// mangle test fixtures.
    init(sink: @escaping @Sendable (Double, Double) async -> Void) {
        let lane = OutboundLane<(Double, Double)>(sink: { await sink($0.0, $0.1) })
        submit = { nx, ny in lane.enqueue((nx, ny), coalescing: .cursorPosition) }
        teardown = { lane.finish() }
    }

    /// Report the latest normalized cursor position. Safe to call from any context; coalesces with a
    /// not-yet-drained prior report (last-wins).
    func report(_ nx: Double, _ ny: Double) {
        submit(nx, ny)
    }

    func finish() {
        teardown()
    }
}

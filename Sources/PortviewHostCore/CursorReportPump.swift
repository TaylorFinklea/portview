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
    private var queue: [(key: CoalesceKey?, message: Message)] = []
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
                    await sink(next)
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
            queue.append((key, message))
        }
        lock.unlock()
        wakeContinuation.yield(())
    }

    /// Stop delivery: pending messages are dropped and later enqueues are ignored. Called from the
    /// owning session's teardown `defer`.
    func finish() {
        lock.lock()
        finished = true
        queue.removeAll()
        lock.unlock()
        wakeContinuation.finish()
        task?.cancel()
        task = nil
    }

    private func take() -> Message? {
        lock.lock()
        defer { lock.unlock() }
        guard !queue.isEmpty else { return nil }
        return queue.removeFirst().message
    }
}

extension OutboundLane where Message == AnyMessage {
    /// Production: drain into a live connection.
    convenience init(connection: PortviewConnection) {
        self.init(sink: { message in try? await connection.send(message) })
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
    /// quantizes to UInt16 — fine here, positions are already normalized 0…1.)
    init(lane: OutboundLane<AnyMessage>) {
        submit = { nx, ny in
            lane.enqueue(.cursorPosition(CursorPosition(normalizedX: nx, normalizedY: ny)),
                         coalescing: .cursorPosition)
        }
        teardown = { lane.finish() }
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

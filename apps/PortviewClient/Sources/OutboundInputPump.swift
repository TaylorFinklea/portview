import Foundation
import PortviewProtocol
import PortviewTransport

/// One ordered outbound lane per connection. A single drain Task awaits each `connection.send` in
/// turn (strict wire order), and consecutive trailing pointer-moves are COALESCED (deltas summed,
/// latest-wins) so a transient send stall can't pile up stale moves that later lurch the host cursor.
/// Discrete events (button/scroll/key/clipboard/viewport) stay ordered and lossless. A fresh pump is
/// bound per connection and torn down with it (see SessionViewModel bind/unbind). Bulk file transfer
/// keeps its own Task so a large push can't head-of-line-block input.
@MainActor
final class OutboundInputPump {
    private var queue: [AnyMessage] = []
    private let wakeContinuation: AsyncStream<Void>.Continuation
    private var task: Task<Void, Never>?

    /// Production: drain into a live connection.
    convenience init(connection: PortviewConnection) {
        self.init(sink: { message in try? await connection.send(message) })
    }

    /// Test seam: drain into an injected async sink (no transport).
    init(sink: @escaping @Sendable (AnyMessage) async -> Void) {
        let (wake, continuation) = AsyncStream<Void>.makeStream()
        self.wakeContinuation = continuation
        self.task = nil // satisfy definite-init before capturing self below
        self.task = Task { [weak self] in
            for await _ in wake {
                while let message = self?.dequeue() {
                    await sink(message)
                }
            }
        }
    }

    /// Enqueue outbound input. Coalesces only with a trailing pointer-move (summing deltas is exactly
    /// equivalent to sending both, since moves are relative) — never across a discrete event.
    func enqueue(_ message: AnyMessage) {
        if case .pointerMove(let move) = message, case .pointerMove(let last)? = queue.last {
            queue[queue.count - 1] = .pointerMove(PointerMove(dx: last.dx + move.dx, dy: last.dy + move.dy))
        } else {
            queue.append(message)
        }
        wakeContinuation.yield(())
    }

    func finish() {
        wakeContinuation.finish()
        task?.cancel()
        task = nil
    }

    private func dequeue() -> AnyMessage? {
        queue.isEmpty ? nil : queue.removeFirst()
    }
}

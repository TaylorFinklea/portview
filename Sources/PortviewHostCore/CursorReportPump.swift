import Foundation
import PortviewProtocol
import PortviewTransport

/// Ordered, coalescing host→client lane for cursor-position reports — the return-path analogue of the
/// client's `OutboundInputPump`. A single drain Task awaits each `connection.send` in turn, so
/// confirmations reach the client in monotonic order: the previous design spawned a detached Task per
/// report, which could complete out of order under load and back-step the client's cursor-follow
/// (visible choppiness). A pending report coalesces to the latest position — the cursor is absolute, so
/// last-wins is exact and the client is predicting locally anyway, so dropping intermediate samples
/// only sheds redundant work. Bound per connection and `finish()`ed when the session tears down.
final class CursorReportPump: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: (Double, Double)?
    private let wakeContinuation: AsyncStream<Void>.Continuation
    private var task: Task<Void, Never>?

    /// Production: drain into a live connection as `.cursorPosition` messages.
    convenience init(connection: PortviewConnection) {
        self.init(sink: { nx, ny in
            try? await connection.send(.cursorPosition(CursorPosition(normalizedX: nx, normalizedY: ny)))
        })
    }

    /// Test seam: drain into an injected async sink (no transport).
    init(sink: @escaping @Sendable (Double, Double) async -> Void) {
        // `.unbounded` is load-bearing: every `report` must deliver a wake so the final resting
        // position can't be stranded in `pending`. (Coalescing sheds intermediate samples via
        // last-wins in `pending`, not by dropping wakes.)
        let (wake, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
        self.wakeContinuation = continuation
        self.task = nil // satisfy definite-init before capturing self below
        self.task = Task { [weak self] in
            for await _ in wake {
                while let next = self?.take() {
                    await sink(next.0, next.1)
                }
            }
        }
    }

    /// Report the latest normalized cursor position. Safe to call from any context; coalesces with a
    /// not-yet-drained prior report (last-wins).
    func report(_ nx: Double, _ ny: Double) {
        lock.lock()
        pending = (nx, ny)
        lock.unlock()
        wakeContinuation.yield(())
    }

    func finish() {
        wakeContinuation.finish()
        task?.cancel()
        task = nil
    }

    private func take() -> (Double, Double)? {
        lock.lock()
        defer { lock.unlock() }
        let value = pending
        pending = nil
        return value
    }
}

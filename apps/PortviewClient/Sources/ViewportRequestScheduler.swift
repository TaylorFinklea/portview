import CoreGraphics
import Foundation

/// Rate-limits host crop (viewport) requests as the magnifier follows the cursor. A **leading +
/// trailing throttle** (not an idle debounce): the first request after a quiet period fires
/// immediately, then at most once per `interval` while requests keep arriving, with a trailing fire
/// for the final resting position. This lets the host crop TRACK the cursor during a continuous pan
/// (so new regions stream in as you move) instead of only re-cropping after you stop — the old idle
/// debounce meant "nothing repaints until I stop, then it takes a beat".
@MainActor
final class ViewportRequestScheduler {
    private static let fullViewport = CGRect(x: 0, y: 0, width: 1, height: 1)

    private let interval: Duration
    private let send: (CGRect) -> Void
    private let clock = ContinuousClock()
    private var pending: CGRect?
    private var lastSent = ViewportRequestScheduler.fullViewport
    private var lastFire: ContinuousClock.Instant?
    private var task: Task<Void, Never>?

    init(interval: Duration = .milliseconds(150), send: @escaping (CGRect) -> Void) {
        self.interval = interval
        self.send = send
    }

    func request(_ rect: CGRect) {
        pending = rect
        guard task == nil else { return }  // a trailing fire is already scheduled; it picks up `pending`
        let elapsed = lastFire.map { clock.now - $0 } ?? interval
        if elapsed >= interval {
            flush()  // leading edge — fire now so re-cropping tracks motion immediately
        } else {
            schedule(after: interval - elapsed)
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        pending = nil
        lastFire = nil
        lastSent = Self.fullViewport
    }

    private func schedule(after delay: Duration) {
        task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            self.flush()
        }
    }

    private func flush() {
        guard let rect = pending else { return }
        pending = nil
        guard !rect.isClose(to: lastSent) else { return }
        // Only an ACTUAL send resets the rate-limit window. If we reset it on a near-duplicate
        // (sub-epsilon cursor jitter), the next real move would find `elapsed < interval` and get
        // deferred into a trailing fire — adding up to `interval` of latency right when you start
        // moving for real.
        lastFire = clock.now
        lastSent = rect
        send(rect)
    }
}

private extension CGRect {
    func isClose(to other: CGRect) -> Bool {
        let epsilon: CGFloat = 0.001
        return abs(minX - other.minX) < epsilon
            && abs(minY - other.minY) < epsilon
            && abs(width - other.width) < epsilon
            && abs(height - other.height) < epsilon
    }
}

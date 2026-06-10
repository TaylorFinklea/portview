import CoreGraphics
import Foundation

@MainActor
final class ViewportRequestScheduler {
    private static let fullViewport = CGRect(x: 0, y: 0, width: 1, height: 1)

    private let delay: Duration
    private let send: (CGRect) -> Void
    private var pending = ViewportRequestScheduler.fullViewport
    private var lastSent = ViewportRequestScheduler.fullViewport
    private var task: Task<Void, Never>?

    init(delay: Duration = .milliseconds(250), send: @escaping (CGRect) -> Void) {
        self.delay = delay
        self.send = send
    }

    func request(_ rect: CGRect) {
        pending = rect
        task?.cancel()
        task = Task { [weak self, delay] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            self?.flushPending()
        }
    }

    func reset() {
        task?.cancel()
        pending = Self.fullViewport
        lastSent = Self.fullViewport
    }

    private func flushPending() {
        let rect = pending
        guard !rect.isClose(to: lastSent) else { return }
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

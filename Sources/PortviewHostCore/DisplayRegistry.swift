import Foundation
@preconcurrency import ScreenCaptureKit

/// The host's live display list, shared across the refresh loop and every per-connection session task.
/// Snapshotted at launch and updated in place when the display configuration changes, so a session's
/// `switchDisplay`/handshake always sees the current set (not a stale launch snapshot).
/// ScreenCaptureKit does not annotate `SCDisplay` as Sendable; we only share these immutable display
/// descriptors, so the lock-guarded array is safe to mark `@unchecked Sendable`.
final class DisplayRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var displays: [SCDisplay]

    init(_ displays: [SCDisplay]) { self.displays = displays }

    func current() -> [SCDisplay] {
        lock.lock(); defer { lock.unlock() }
        return displays
    }

    func set(_ new: [SCDisplay]) {
        lock.lock(); defer { lock.unlock() }
        displays = new
    }
}

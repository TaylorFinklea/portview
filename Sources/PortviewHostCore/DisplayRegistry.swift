import Foundation
@preconcurrency import ScreenCaptureKit

/// ScreenCaptureKit does not annotate `SCDisplay` as Sendable; we only ever share these immutable
/// display descriptors across the actor boundary below, so asserting Sendable here is safe.
extension SCDisplay: @unchecked @retroactive Sendable {}

/// The host's live display list, shared across the refresh loop and every per-connection session task.
/// Snapshotted at launch and updated in place when the display configuration changes, so a session's
/// `switchDisplay`/handshake always sees the current set (not a stale launch snapshot). All callers
/// are already in async contexts, so actor isolation replaces the hand-rolled lock.
actor DisplayRegistry {
    private var displays: [SCDisplay]

    init(_ displays: [SCDisplay]) { self.displays = displays }

    func current() -> [SCDisplay] {
        displays
    }

    func set(_ new: [SCDisplay]) {
        displays = new
    }
}

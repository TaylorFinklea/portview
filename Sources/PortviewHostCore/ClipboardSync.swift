// SPDX-License-Identifier: Apache-2.0
import Foundation
@preconcurrency import AppKit

/// The subset of `NSPasteboard` `ClipboardSync` touches, seamed so tests can substitute a fake
/// (mirrors `InputInjector.postEvent` — a real `applyRemote` write is a live, observable side
/// effect on the dev machine). Method signatures match `NSPasteboard`'s exactly, so it conforms
/// via a bare extension with no wrapper.
protocol ClipboardPasteboard: AnyObject {
    var changeCount: Int { get }
    @discardableResult func clearContents() -> Int
    @discardableResult func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
    func string(forType dataType: NSPasteboard.PasteboardType) -> String?
}

extension NSPasteboard: ClipboardPasteboard {}

/// Mirrors the Mac pasteboard to/from the client. macOS has no pasteboard-change notification, so
/// local copies are detected by polling `changeCount`; remote updates are applied and the change
/// count recorded so they don't echo straight back.
///
/// `NSPasteboard` is AppKit and must only be touched on the main thread — accessing it from a
/// background task corrupts memory (a real crash we hit). So ALL pasteboard access (poll + apply)
/// runs on the main actor, which also serializes `lastChangeCount`.
final class ClipboardSync: @unchecked Sendable {
    private let pasteboard: ClipboardPasteboard
    private var lastChangeCount = 0
    private var pollTask: Task<Void, Never>?
    /// Per-session act-permission gate (han.4 Task 5, design §4/§7 invariant 2). `applyRemote`'s
    /// deferred `Task { @MainActor }` rechecks this INSIDE the task, at the instant the single
    /// pasteboard mutation would run — not just when `applyRemote` was called — so a write queued
    /// before a normal teardown OR a revoke still drops if invalidation lands first (H-d).
    private let capability: SessionCapability

    init(pasteboard: ClipboardPasteboard = NSPasteboard.general, capability: SessionCapability) {
        self.pasteboard = pasteboard
        self.capability = capability
    }

    /// Begin polling; `onLocalCopy` fires when the Mac's pasteboard text changes locally.
    func start(onLocalCopy: @escaping @Sendable (String) -> Void) {
        pollTask = Task { @MainActor [weak self] in
            self?.lastChangeCount = self?.pasteboard.changeCount ?? 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                let count = self.pasteboard.changeCount
                guard count != self.lastChangeCount else { continue }
                self.lastChangeCount = count
                if let text = self.pasteboard.string(forType: .string), !text.isEmpty {
                    onLocalCopy(text)
                }
            }
        }
    }

    /// Apply a clipboard update received from the client (without echoing it back).
    func applyRemote(_ text: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // The recheck runs HERE, inside the deferred task, not at `applyRemote`'s call site —
            // the whole point of the seam (finding 3 / H-d): a capability valid when `applyRemote`
            // was called but invalidated before this task got to run must still drop the write.
            self.capability.perform {
                self.pasteboard.clearContents()
                self.pasteboard.setString(text, forType: .string)
                self.lastChangeCount = self.pasteboard.changeCount
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }
}

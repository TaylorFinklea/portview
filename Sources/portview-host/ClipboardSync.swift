import Foundation
@preconcurrency import AppKit

/// Mirrors the Mac pasteboard to/from the client. macOS has no pasteboard-change notification, so
/// local copies are detected by polling `changeCount`; remote updates are applied and the change
/// count recorded so they don't echo straight back.
///
/// `NSPasteboard` is AppKit and must only be touched on the main thread — accessing it from a
/// background task corrupts memory (a real crash we hit). So ALL pasteboard access (poll + apply)
/// runs on the main actor, which also serializes `lastChangeCount`.
final class ClipboardSync: @unchecked Sendable {
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount = 0
    private var pollTask: Task<Void, Never>?

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
            self.pasteboard.clearContents()
            self.pasteboard.setString(text, forType: .string)
            self.lastChangeCount = self.pasteboard.changeCount
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }
}

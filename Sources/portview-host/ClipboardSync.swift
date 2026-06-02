import Foundation
@preconcurrency import AppKit

/// Mirrors the Mac pasteboard to/from the client. macOS has no pasteboard-change
/// notification, so local copies are detected by polling `changeCount`; remote updates are
/// applied and the change count recorded so they don't echo straight back.
final class ClipboardSync: @unchecked Sendable {
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var pollTask: Task<Void, Never>?

    /// Begin polling; `onLocalCopy` fires when the Mac's pasteboard text changes locally.
    func start(onLocalCopy: @escaping @Sendable (String) -> Void) {
        lastChangeCount = pasteboard.changeCount
        pollTask = Task { [weak self] in
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
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChangeCount = pasteboard.changeCount
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }
}

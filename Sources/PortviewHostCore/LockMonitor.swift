import Foundation
import CoreGraphics

/// Detects the host's screen lock/unlock so the client can pause/resume its live view (a locked Mac
/// captures the secure desktop / blank, not the user's content). Seeds the initial state from the
/// authoritative CoreGraphics session dictionary, then listens for the (undocumented but long-stable,
/// non-sandboxed-only) `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` distributed
/// notifications. `onChange` fires only on an actual state transition.
///
/// The distributed-notification strings are not formal API (Apple DTS: may change), so the CoreGraphics
/// dictionary is the authoritative seed and a connecting client is also told the current state at
/// handshake — the notifications are the live delta, not the source of truth for security decisions.
final class LockMonitor: @unchecked Sendable {
    private let center: DistributedNotificationCenter
    private let onChange: @Sendable (Bool) -> Void
    private var observers: [NSObjectProtocol] = []
    /// Last forwarded state, for dedup. Seeded once in `start()` (on whatever thread calls it, before
    /// any observer is registered — so the write is sequenced-before delivery), then touched only on
    /// `.main` by the observer callbacks.
    private var lastLocked: Bool?

    init(center: DistributedNotificationCenter = .default(), onChange: @escaping @Sendable (Bool) -> Void) {
        self.center = center
        self.onChange = onChange
    }

    func start() {
        // Seed the dedup baseline from the authoritative dictionary WITHOUT emitting — at startup there
        // are no clients to broadcast to, and emitting here would log a spurious "unlocked" transition
        // on every launch. New clients get the current state via the handshake seed; this monitor only
        // forwards live lock/unlock CHANGES from here on.
        lastLocked = Self.currentlyLocked()
        observers = [
            center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                               object: nil, queue: .main) { [weak self] _ in self?.emit(true) },
            center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                               object: nil, queue: .main) { [weak self] _ in self?.emit(false) },
        ]
    }

    func stop() {
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    /// Forward only on a real transition (the lock/unlock notifications can repeat).
    func emit(_ locked: Bool) {
        if lastLocked == locked { return }
        lastLocked = locked
        onChange(locked)
    }

    /// The authoritative current lock state from the GUI session that owns the console.
    static func currentlyLocked() -> Bool {
        screenLocked(from: CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    /// Pure parse: locked iff `CGSSessionScreenIsLocked` is present and truthy (the key is ABSENT
    /// when unlocked, so presence ≈ locked).
    static func screenLocked(from dict: [String: Any]?) -> Bool {
        guard let value = dict?["CGSSessionScreenIsLocked"] else { return false }
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.intValue == 1 }
        if let i = value as? Int { return i == 1 }
        return true // present but unrecognized type → treat as locked
    }
}

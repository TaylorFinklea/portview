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
    /// The host owner's live clipboard opt-in (default OFF). Checked at the TWO irreducible
    /// boundaries this type owns: every pasteboard READ in the poll (so a disabled host never even
    /// looks at the pasteboard) and the pasteboard WRITE in `applyRemote`. Lock order is
    /// capability -> policy; `policy.perform` holds the policy lock across the synchronous effect,
    /// so a disable returns only after any in-flight read/write has finished.
    private let policy: HostAccessPolicy
    private let pollInterval: Duration

    init(pasteboard: ClipboardPasteboard = NSPasteboard.general, capability: SessionCapability,
         policy: HostAccessPolicy, pollInterval: Duration = .milliseconds(500)) {
        self.pasteboard = pasteboard
        self.capability = capability
        self.policy = policy
        self.pollInterval = pollInterval
    }

    private enum Tick {
        case baseline(Int, UInt64)
        case unchanged
        case changed(Int, String?)
    }

    /// Begin polling; `onLocalCopy` fires when the Mac's pasteboard text changes locally.
    func start(onLocalCopy: @escaping @Sendable (String) -> Void) {
        let policy = self.policy
        pollTask = Task { @MainActor [weak self] in
            // `enabledLastTick` is false until a read has actually been permitted. The first
            // permitted read after any disabled stretch only RE-BASELINES the change count: a copy
            // made while the channel was off must never be sent once it is switched on.
            // `baselineGeneration` is the clipboard disable generation the baseline was taken under.
            // A disable+re-enable that falls BETWEEN two ticks is invisible to `enabledLastTick`, but
            // it bumps the generation, so the next tick still re-baselines instead of sending a copy
            // made while the channel was off.
            var enabledLastTick = false
            var baselineGeneration: UInt64 = 0
            if let self {
                let first: (Int, UInt64)? = policy.performWithGeneration(.clipboard) { gen in
                    (self.pasteboard.changeCount, gen)
                }
                if let (count, gen) = first {
                    self.lastChangeCount = count
                    baselineGeneration = gen
                    enabledLastTick = true
                }
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.pollInterval ?? .milliseconds(500))
                guard let self else { return }
                let wasEnabled = enabledLastTick
                let knownGeneration = baselineGeneration
                // Count AND text are read inside ONE policy hold (generation read in the same hold);
                // disabled => no pasteboard access.
                let tick: Tick? = policy.performWithGeneration(.clipboard) { gen in
                    let count = self.pasteboard.changeCount
                    guard wasEnabled, gen == knownGeneration else { return .baseline(count, gen) }
                    guard count != self.lastChangeCount else { return .unchanged }
                    return .changed(count, self.pasteboard.string(forType: .string))
                }
                guard let tick else { enabledLastTick = false; continue }
                enabledLastTick = true
                switch tick {
                case .baseline(let count, let gen):
                    self.lastChangeCount = count
                    baselineGeneration = gen
                case .unchanged:
                    break
                case .changed(let count, let text):
                    self.lastChangeCount = count
                    if let text, !text.isEmpty {
                        // Re-checked at the send boundary: a disable that landed after the read
                        // drops the copy here (the outbound sink checks again at submission).
                        _ = policy.perform(.clipboard) { onLocalCopy(text) }
                    }
                }
            }
        }
    }

    /// Apply a clipboard update received from the client (without echoing it back).
    ///
    /// The policy state is captured HERE, at receive time: an update that arrives while clipboard
    /// sync is disabled is dropped outright (enabling later must never apply it), and the disable
    /// generation is recorded so an off->on cycle between receive and write also drops it.
    func applyRemote(_ text: String) {
        guard let receivedGeneration = policy.performWithGeneration(.clipboard, { $0 }) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // The recheck runs HERE, inside the deferred task, not at `applyRemote`'s call site —
            // the whole point of the seam (finding 3 / H-d): a capability valid when `applyRemote`
            // was called but invalidated before this task got to run must still drop the write.
            // The policy check is nested INSIDE the capability's closure (capability -> policy) for
            // the same reason: a disable that lands while the task is queued must still drop it.
            self.capability.perform {
                _ = self.policy.performWithGeneration(.clipboard) { gen in
                    guard gen == receivedGeneration else { return }
                    self.pasteboard.clearContents()
                    self.pasteboard.setString(text, forType: .string)
                    self.lastChangeCount = self.pasteboard.changeCount
                }
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }
}

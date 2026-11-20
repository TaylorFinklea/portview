// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Persists whether the first-run walkthrough has been completed (or skipped). The suite is
/// injectable so tests never touch the standard defaults domain.
final class FirstRunStateStore {
    private static let key = "portview.firstRun.walkthroughCompleted"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var hasCompletedWalkthrough: Bool { defaults.bool(forKey: Self.key) }

    /// Idempotent.
    func complete() { defaults.set(true, forKey: Self.key) }
}

/// Whether the walkthrough is on screen. Showing it again from Settings is purely presentational;
/// completion state is only written when the user finishes or skips.
struct WalkthroughPresentation {
    private let store: FirstRunStateStore
    private(set) var isPresented: Bool

    init(store: FirstRunStateStore) {
        self.store = store
        self.isPresented = !store.hasCompletedWalkthrough
    }

    mutating func showAgain() { isPresented = true }

    mutating func finish() {
        store.complete()
        isPresented = false
    }
}

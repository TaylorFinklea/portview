// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The host owner's live opt-in for the two privacy-sensitive channels (clipboard sync, file
/// transfer), enforced at the host's irreducible effect boundaries — never by hiding client UI,
/// because the client is untrusted input (2026-07-28 ADR). Both default OFF.
///
/// One instance per `HostControl` (so one per host process), shared by every session's
/// `ClipboardSync`/`FileReceiver`/outbound sink by construction.
///
/// Three properties matter beyond a bare boolean:
///
/// 1. **Serialization with effects.** `perform` holds the policy lock ACROSS a strictly synchronous
///    effect, and `update` takes the same lock — so a disable returns only after any in-flight
///    effect has finished, and no new one starts afterwards. "Disabled" therefore means disabled
///    for already-connected sessions before the toggle action returns.
/// 2. **Disable generation.** Each feature carries a counter bumped on every enabled→disabled
///    transition. A multi-step operation (an inbound file transfer) records it at its start and
///    treats a later mismatch as "a disable happened since" even if the feature was re-enabled.
/// 3. **Lock order: `SessionCapability.perform` → policy.** Effect boundaries call
///    `policy.perform` INSIDE the capability's closure; nothing here ever calls into a
///    capability, so the order is one-directional. The effect closure must never `await`, hop
///    actors, or call back into this policy (the lock is non-reentrant).
/// 4. **Async sends are checked at submission.** No lock may be held across `await
///    connection.send`, so the outbound sink checks the policy just before the send; at most one
///    message already authorized at that check may still reach the transport after a disable returns.
public final class HostAccessPolicy: @unchecked Sendable {
    public enum Feature: Sendable {
        case clipboard
        case fileTransfer
    }

    private let lock = NSLock()
    private var clipboard: Bool
    private var files: Bool
    private var clipboardDisableGeneration: UInt64 = 0
    private var filesDisableGeneration: UInt64 = 0

    /// Secure default: everything off.
    public init(clipboardEnabled: Bool = false, fileTransferEnabled: Bool = false) {
        clipboard = clipboardEnabled
        files = fileTransferEnabled
    }

    public var clipboardEnabled: Bool { isEnabled(.clipboard) }
    public var fileTransferEnabled: Bool { isEnabled(.fileTransfer) }

    public func isEnabled(_ feature: Feature) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled(feature)
    }

    /// The feature's disable generation (bumped on each enabled→disabled transition).
    public func disableGeneration(_ feature: Feature) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return generation(feature)
    }

    /// True iff the feature is enabled AND no disable has happened since `generation` was read.
    /// For long-running operations that cannot hold the lock (an outbound file transfer).
    public func permits(_ feature: Feature, sinceGeneration generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled(feature) && self.generation(feature) == generation
    }

    /// Apply new values. Blocks behind any in-flight `perform` effect, so on return no effect for a
    /// feature that is now disabled is running or can start.
    public func update(clipboardEnabled: Bool, fileTransferEnabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        if clipboard && !clipboardEnabled { clipboardDisableGeneration &+= 1 }
        if files && !fileTransferEnabled { filesDisableGeneration &+= 1 }
        clipboard = clipboardEnabled
        files = fileTransferEnabled
    }

    /// Run a strictly synchronous `effect` only if `feature` is enabled, holding the policy lock for
    /// its whole duration. Returns `nil` (effect not run) when disabled.
    public func perform<T>(_ feature: Feature, _ effect: () throws -> T) rethrows -> T? {
        try performWithGeneration(feature) { _ in try effect() }
    }

    /// As `perform`, passing the feature's disable generation read under the same lock hold, so the
    /// effect can compare it with one recorded earlier atomically with the effect itself.
    public func performWithGeneration<T>(_ feature: Feature, _ effect: (UInt64) throws -> T) rethrows -> T? {
        lock.lock(); defer { lock.unlock() }
        guard enabled(feature) else { return nil }
        return try effect(generation(feature))
    }

    // Callers hold `lock`.
    private func enabled(_ feature: Feature) -> Bool {
        switch feature {
        case .clipboard: return clipboard
        case .fileTransfer: return files
        }
    }

    private func generation(_ feature: Feature) -> UInt64 {
        switch feature {
        case .clipboard: return clipboardDisableGeneration
        case .fileTransfer: return filesDisableGeneration
        }
    }
}

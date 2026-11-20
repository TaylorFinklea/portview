// SPDX-License-Identifier: Apache-2.0
import Foundation
import PortviewProtocol
import os

private let logger = Logger(subsystem: "dev.finklea.portview", category: "files")

/// Receives files pushed from the client (a `FileOffer` then ordered `FileChunk`s) and writes
/// them into ~/Downloads, de-duplicating the filename. Tracks one in-flight transfer per id.
final class FileReceiver {
    /// Per-transfer cap. `offer.size` is client-reported and untrusted, so this bounds actual
    /// bytes written regardless of what the offer claims.
    static let defaultMaxFileSize: UInt64 = 2 * 1024 * 1024 * 1024 // 2 GiB
    /// Total bytes writable across all transfers for the lifetime of this receiver (one per
    /// session), independent of the per-file cap.
    static let defaultMaxSessionSize: UInt64 = 8 * 1024 * 1024 * 1024 // 8 GiB

    private struct Transfer {
        let handle: FileHandle
        let url: URL
        var received: UInt64
        /// The file policy's disable generation when this transfer was offered. A mismatch later
        /// means the owner switched file transfer off at some point since — even if it is on again
        /// now — and the transfer is dead (the peer must re-offer).
        let generation: UInt64
    }
    private var transfers: [UInt32: Transfer] = [:]
    private let directory: URL
    private let maxFileSize: UInt64
    private let maxSessionSize: UInt64
    private var sessionTotal: UInt64 = 0
    /// Per-session act-permission gate (han.4 Task 5, design §4/§7 invariant 2). FOUR irreducible
    /// effect boundaries are gated — `offer`'s `createFile`, `chunk`'s `handle.write`, `chunk`'s
    /// finalizing `handle.close`, and `dropTransfer`'s close+unlink — so an invalidated capability
    /// skips each effect itself, never a whole-message guard. (Sol review I4b added the last two:
    /// a zero-length final chunk and a quota-crossing chunk each reached an unguarded effect.)
    private let capability: SessionCapability
    /// The host owner's live file-transfer opt-in (default OFF), enforced beside the capability at
    /// the same four boundaries. Always nested capability -> policy (`policy.perform` inside the
    /// capability closure); `policy.perform` holds its lock across the synchronous file effect, so a
    /// disable returns only after any in-flight write/close/unlink has finished.
    private let policy: HostAccessPolicy

    init(
        directory: URL? = nil,
        maxFileSize: UInt64 = FileReceiver.defaultMaxFileSize,
        maxSessionSize: UInt64 = FileReceiver.defaultMaxSessionSize,
        capability: SessionCapability,
        policy: HostAccessPolicy
    ) {
        self.directory = directory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        self.maxFileSize = maxFileSize
        self.maxSessionSize = maxSessionSize
        self.capability = capability
        self.policy = policy
    }

    func offer(_ offer: FileOffer) {
        // Refuse BEFORE the filename probe: a disabled host must not even stat ~/Downloads on a
        // client-supplied name.
        guard policy.isEnabled(.fileTransfer) else { return }
        let url = uniqueURL(for: offer.name)
        // SELF-guard at the irreducible boundary, mirroring `chunk`'s `handle.write`: creating the
        // file IS an effect of its own, so a post-invalidate offer (reachable through the bounded R9
        // one-message parked-waiter window) must not leave a 0-byte client-named file in ~/Downloads.
        // The serve loop calls this UNWRAPPED — an outer `capability.perform` would self-deadlock the
        // non-reentrant lock. The policy check is nested inside (capability -> policy) and re-checked
        // under the policy lock, so a disable between the check above and the create still wins.
        var generation: UInt64?
        capability.perform {
            generation = policy.performWithGeneration(.fileTransfer) { gen in
                _ = FileManager.default.createFile(atPath: url.path, contents: nil)
                return gen
            }
        }
        guard let generation else { return }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            logger.error("file transfer: could not open \(url.path) for writing")
            return
        }
        transfers[offer.transferID] = Transfer(handle: handle, url: url, received: 0, generation: generation)
        logger.info("Receiving \"\(offer.name)\" (\(offer.size, privacy: .public) bytes) → \(url.path)")
    }

    func chunk(_ chunk: FileChunk) {
        guard var transfer = transfers[chunk.transferID] else { return }
        if !chunk.data.isEmpty {
            let incoming = UInt64(chunk.data.count)
            if transfer.received + incoming > maxFileSize || sessionTotal + incoming > maxSessionSize {
                dropTransfer(chunk.transferID, transfer)
                return
            }
            let wrote = runTransferEffect(chunk.transferID, transfer) {
                try? transfer.handle.write(contentsOf: Data(chunk.data))
            }
            guard wrote == .ran else { return }
            transfer.received += incoming
            sessionTotal += incoming
            transfers[chunk.transferID] = transfer
        }
        if chunk.isLast {
            // SELF-guard at the irreducible boundary (Sol review I4b): COMPLETING a transfer is an
            // effect of its own. A zero-length final chunk skips the write branch above entirely, so
            // without this a revoked peer could still close the handle and commit the transfer
            // through the bounded R9 parked-waiter window. When the gate refuses, the transfer stays
            // in flight and the serve defer's `cancelAll` reclaims the handle instead.
            let finalized = runTransferEffect(chunk.transferID, transfer) { try? transfer.handle.close() }
            guard finalized == .ran else { return }
            transfers[chunk.transferID] = nil
            logger.info("Saved \(transfer.url.lastPathComponent) (\(transfer.received, privacy: .public) bytes).")
        }
    }

    private enum EffectOutcome { case ran, refused, stale }

    /// Run ONE irreducible effect of an in-flight transfer behind BOTH gates, capability then policy
    /// (the only lock order). Staleness is decided first: if a disable happened since the offer
    /// (generation mismatch, whether or not files are enabled again), the transfer is dead — the
    /// host's own partial file is closed and removed and the id forgotten, all inside the capability
    /// gate, and the effect does NOT run. Otherwise the effect runs under the policy lock, which
    /// re-checks the generation so a disable racing between the two reads cannot slip a write in.
    private func runTransferEffect(_ id: UInt32, _ transfer: Transfer, _ effect: () -> Void) -> EffectOutcome {
        var outcome = EffectOutcome.refused
        capability.perform {
            if policy.disableGeneration(.fileTransfer) != transfer.generation {
                discardStale(id, transfer)
                outcome = .stale
                return
            }
            let ran = policy.performWithGeneration(.fileTransfer) { gen -> Bool in
                guard gen == transfer.generation else { return false }
                effect()
                return true
            }
            outcome = ran == true ? .ran : .refused
        }
        return outcome
    }

    /// Close + unlink the host's own partial file for a transfer a disable invalidated. Runs inside
    /// the caller's `capability.perform` (never takes it again — non-reentrant). Deliberately not
    /// behind the policy: it only removes what this receiver itself created, and must work while
    /// files are disabled (that is exactly when a stale transfer needs reclaiming).
    private func discardStale(_ id: UInt32, _ transfer: Transfer) {
        try? transfer.handle.close()
        try? FileManager.default.removeItem(at: transfer.url)
        transfers[id] = nil
        logger.warning("file transfer: \(transfer.url.lastPathComponent) invalidated by a file-transfer disable, discarded.")
    }

    /// Over the per-file or per-session cap: close the handle, delete the partial file, and drop
    /// the transfer (no further chunks for this id will be written).
    ///
    /// SELF-guarded (Sol review I4b): deleting a file is the most destructive effect this type has,
    /// and the quota branch reaches it WITHOUT going through the write's gate — so a revoked peer
    /// could make a ~/Downloads file disappear with one over-cap chunk. Close+unlink of the SAME
    /// file is the irreducible boundary here and is deliberately NOT split: unlinking a still-open
    /// handle, or closing without unlinking, would each leave a half-dropped transfer. When the gate
    /// refuses, nothing is deleted and the transfer stays in flight (further chunks re-enter here
    /// and are refused again); the serve defer's `cancelAll` reclaims the handle.
    private func dropTransfer(_ transferID: UInt32, _ transfer: Transfer) {
        let dropped = runTransferEffect(transferID, transfer) {
            try? transfer.handle.close()
            try? FileManager.default.removeItem(at: transfer.url)
        }
        guard dropped == .ran else { return }
        transfers[transferID] = nil
        logger.warning("file transfer: \(transfer.url.lastPathComponent) exceeded size cap, dropped.")
    }

    /// Test seam: the transfers still in flight — neither finalized (`isLast`) nor dropped
    /// (over-cap). Lets the capability-gating tests observe that a post-withdrawal message did not
    /// finalize or drop a transfer, which is otherwise invisible on disk.
    var inFlightTransferIDs: Set<UInt32> { Set(transfers.keys) }

    func cancelAll() {
        for (_, transfer) in transfers { try? transfer.handle.close() }
        transfers.removeAll()
    }

    /// Sanitize to a bare filename and append " (n)" until the path is free.
    private func uniqueURL(for rawName: String) -> URL {
        let safe = (rawName as NSString).lastPathComponent
        let name = safe.isEmpty ? "portview-file" : safe
        var candidate = directory.appendingPathComponent(name)
        let ext = candidate.pathExtension
        let base = candidate.deletingPathExtension().lastPathComponent
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let newName = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = directory.appendingPathComponent(newName)
            counter += 1
        }
        return candidate
    }
}

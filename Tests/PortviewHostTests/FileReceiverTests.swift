// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import PortviewProtocol
@testable import PortviewHostCore

/// `FileReceiver` writes inbound `FileOffer`/`FileChunk` pushes into a directory, treating
/// `offer.size` as untrusted and enforcing an actual per-file cap and per-session total cap.
@Suite struct FileReceiverTests {
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileReceiverTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func overCapTransferIsDroppedAndFileDeleted() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let receiver = FileReceiver(directory: dir, maxFileSize: 10, maxSessionSize: 1000, capability: SessionCapability())

        // offer.size lies about the true size — must not be trusted.
        receiver.offer(FileOffer(transferID: 1, name: "big.bin", size: 1))
        receiver.chunk(FileChunk(transferID: 1, isLast: false, data: Array(repeating: 0, count: 6)))
        receiver.chunk(FileChunk(transferID: 1, isLast: true, data: Array(repeating: 0, count: 6)))

        let url = dir.appendingPathComponent("big.bin")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func underCapTransferWritesFully() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let receiver = FileReceiver(directory: dir, maxFileSize: 1000, maxSessionSize: 1000, capability: SessionCapability())

        receiver.offer(FileOffer(transferID: 2, name: "small.bin", size: 12))
        receiver.chunk(FileChunk(transferID: 2, isLast: false, data: Array(repeating: 1, count: 6)))
        receiver.chunk(FileChunk(transferID: 2, isLast: true, data: Array(repeating: 1, count: 6)))

        let url = dir.appendingPathComponent("small.bin")
        let contents = try? Data(contentsOf: url)
        #expect(contents?.count == 12)
    }

    @Test func sessionQuotaDropsSecondTransferOnceExceeded() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let receiver = FileReceiver(directory: dir, maxFileSize: 1000, maxSessionSize: 10, capability: SessionCapability())

        receiver.offer(FileOffer(transferID: 3, name: "a.bin", size: 8))
        receiver.chunk(FileChunk(transferID: 3, isLast: true, data: Array(repeating: 1, count: 8)))

        receiver.offer(FileOffer(transferID: 4, name: "b.bin", size: 8))
        receiver.chunk(FileChunk(transferID: 4, isLast: true, data: Array(repeating: 1, count: 8)))

        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.bin").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("b.bin").path))
    }

    /// han.4 Task 5 (design §4/§8): `chunk`'s single `handle.write` is the irreducible effect
    /// boundary — an invalidated capability must skip the write entirely, not just log/no-op
    /// after the fact. The offer lands while the capability is still VALID (so the transfer really
    /// is in flight); invalidation lands between the offer and the chunk.
    @Test func chunkUnderInvalidatedCapabilityDoesNotWrite() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capability = SessionCapability()
        let receiver = FileReceiver(directory: dir, maxFileSize: 1000, maxSessionSize: 1000, capability: capability)

        receiver.offer(FileOffer(transferID: 5, name: "gated.bin", size: 6))
        capability.invalidate()
        receiver.chunk(FileChunk(transferID: 5, isLast: false, data: Array(repeating: 1, count: 6)))

        let url = dir.appendingPathComponent("gated.bin")
        let contents = try? Data(contentsOf: url)
        #expect(contents?.count == 0)
    }

    /// Final-review M-2 (design §7 invariant 2): `offer`'s `createFile` is an irreducible effect of
    /// its own, so it must be capability-gated exactly like `chunk`'s write. Otherwise a `.fileOffer`
    /// arriving through the bounded R9 parked-waiter window creates a 0-byte, client-named file in
    /// ~/Downloads after the session's authority is gone.
    @Test func offerUnderInvalidatedCapabilityCreatesNoFile() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capability = SessionCapability()
        capability.invalidate()
        let receiver = FileReceiver(directory: dir, maxFileSize: 1000, maxSessionSize: 1000, capability: capability)

        receiver.offer(FileOffer(transferID: 6, name: "ghost.bin", size: 6))

        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("ghost.bin").path))
        // Nothing at all — not even under a de-duplicated " (1)" name.
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true)
    }

    /// Sol review I4(b), first gap (design §7 invariant 2): a ZERO-LENGTH final chunk skips the
    /// `!data.isEmpty` branch entirely, so it never reached `capability.perform` — and still closed
    /// the handle and completed the transfer. Finalization is an effect of its own and must be gated
    /// at its irreducible boundary like the write is; a session whose authority is gone may not
    /// commit a transfer. The bytes written BEFORE the withdrawal stay on disk (already committed);
    /// the handle is reclaimed by the serve defer's `cancelAll`, not by the revoked peer.
    @Test func emptyFinalChunkUnderInvalidatedCapabilityDoesNotFinalizeTheTransfer() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capability = SessionCapability()
        let receiver = FileReceiver(directory: dir, maxFileSize: 1000, maxSessionSize: 1000, capability: capability)

        receiver.offer(FileOffer(transferID: 8, name: "half.bin", size: 12))
        receiver.chunk(FileChunk(transferID: 8, isLast: false, data: Array(repeating: 1, count: 6)))
        #expect(receiver.inFlightTransferIDs == [8])

        capability.invalidate()
        receiver.chunk(FileChunk(transferID: 8, isLast: true, data: []))

        #expect(receiver.inFlightTransferIDs == [8])   // NOT finalized by the revoked peer
        #expect((try? Data(contentsOf: dir.appendingPathComponent("half.bin")))?.count == 6)
        receiver.cancelAll()                            // the serve defer reclaims the handle
        #expect(receiver.inFlightTransferIDs.isEmpty)
    }

    /// The gate must not break the normal path: with a live capability the same zero-length final
    /// chunk still finalizes the transfer.
    @Test func emptyFinalChunkUnderAValidCapabilityFinalizes() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let receiver = FileReceiver(directory: dir, maxFileSize: 1000, maxSessionSize: 1000,
                                    capability: SessionCapability())

        receiver.offer(FileOffer(transferID: 9, name: "whole.bin", size: 6))
        receiver.chunk(FileChunk(transferID: 9, isLast: false, data: Array(repeating: 1, count: 6)))
        receiver.chunk(FileChunk(transferID: 9, isLast: true, data: []))

        #expect(receiver.inFlightTransferIDs.isEmpty)
        #expect((try? Data(contentsOf: dir.appendingPathComponent("whole.bin")))?.count == 6)
    }

    /// Sol review I4(b), second gap (design §7 invariant 2): a quota-crossing chunk called
    /// `dropTransfer` UNGUARDED, which closes the handle **and deletes** the partial file. That is a
    /// destructive filesystem mutation performed by a session whose authority is already withdrawn —
    /// a revoked peer could still make a file disappear from ~/Downloads by pushing one over-cap
    /// chunk through the bounded R9 parked-waiter window.
    @Test func quotaCrossingChunkUnderInvalidatedCapabilityDoesNotDeleteThePartialFile() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capability = SessionCapability()
        let receiver = FileReceiver(directory: dir, maxFileSize: 10, maxSessionSize: 1000, capability: capability)

        receiver.offer(FileOffer(transferID: 10, name: "partial.bin", size: 6))
        receiver.chunk(FileChunk(transferID: 10, isLast: false, data: Array(repeating: 1, count: 6)))
        let url = dir.appendingPathComponent("partial.bin")
        #expect((try? Data(contentsOf: url))?.count == 6)

        capability.invalidate()
        // 6 + 6 > maxFileSize(10) → the over-cap drop path.
        receiver.chunk(FileChunk(transferID: 10, isLast: false, data: Array(repeating: 1, count: 6)))

        #expect(FileManager.default.fileExists(atPath: url.path))   // not deleted
        #expect((try? Data(contentsOf: url))?.count == 6)           // and never grew
        #expect(receiver.inFlightTransferIDs == [10])               // not dropped either
        receiver.cancelAll()
    }

    /// The transfer is not registered either, so a following chunk is a no-op rather than writing
    /// into a stale handle.
    @Test func chunkAfterGatedOfferIsANoOp() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capability = SessionCapability()
        capability.invalidate()
        let receiver = FileReceiver(directory: dir, maxFileSize: 1000, maxSessionSize: 1000, capability: capability)

        receiver.offer(FileOffer(transferID: 7, name: "ghost2.bin", size: 6))
        receiver.chunk(FileChunk(transferID: 7, isLast: true, data: Array(repeating: 1, count: 6)))

        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true)
    }
}

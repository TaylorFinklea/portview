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

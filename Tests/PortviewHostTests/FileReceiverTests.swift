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
        let receiver = FileReceiver(directory: dir, maxFileSize: 10, maxSessionSize: 1000)

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
        let receiver = FileReceiver(directory: dir, maxFileSize: 1000, maxSessionSize: 1000)

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
        let receiver = FileReceiver(directory: dir, maxFileSize: 1000, maxSessionSize: 10)

        receiver.offer(FileOffer(transferID: 3, name: "a.bin", size: 8))
        receiver.chunk(FileChunk(transferID: 3, isLast: true, data: Array(repeating: 1, count: 8)))

        receiver.offer(FileOffer(transferID: 4, name: "b.bin", size: 8))
        receiver.chunk(FileChunk(transferID: 4, isLast: true, data: Array(repeating: 1, count: 8)))

        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.bin").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("b.bin").path))
    }
}

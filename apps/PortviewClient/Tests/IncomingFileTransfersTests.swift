import XCTest
import PortviewProtocol

@testable import PortviewClient

/// `IncomingFileTransfers` size caps: `offer.size` is host-reported and untrusted, so the
/// receiver bounds ACTUAL bytes written — a per-file cap and a per-session total cap — and an
/// over-cap transfer is dropped with its partial file deleted (mirrors the host's `FileReceiver`).
final class IncomingFileTransfersTests: XCTestCase {
    /// Transfers land in per-transfer UUID subdirectories of the shared PortviewIncoming root, so
    /// tests locate a file by its (test-unique) name rather than a predictable path.
    private func fileExists(named name: String) -> Bool {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortviewIncoming", isDirectory: true)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == name { return true }
        }
        return false
    }

    func testOverFileCapTransferIsDroppedAndPartialFileDeleted() {
        let name = "big-\(UUID().uuidString).bin"
        let transfers = IncomingFileTransfers(maxFileSize: 10, maxSessionSize: 1000)

        // offer.size lies about the true size — must not be trusted.
        XCTAssertEqual(transfers.offer(FileOffer(transferID: 1, name: name, size: 1)), name)
        XCTAssertNil(transfers.chunk(FileChunk(transferID: 1, isLast: false, data: Array(repeating: 0, count: 6))))
        XCTAssertTrue(fileExists(named: name)) // partial write landed on disk
        XCTAssertNil(transfers.chunk(FileChunk(transferID: 1, isLast: true, data: Array(repeating: 0, count: 6))))
        XCTAssertFalse(fileExists(named: name)) // over cap → dropped, partial file deleted
    }

    func testSessionCapDropsSecondTransferOnceExceeded() {
        let nameA = "a-\(UUID().uuidString).bin"
        let nameB = "b-\(UUID().uuidString).bin"
        let transfers = IncomingFileTransfers(maxFileSize: 1000, maxSessionSize: 10)

        transfers.offer(FileOffer(transferID: 3, name: nameA, size: 8))
        let first = transfers.chunk(FileChunk(transferID: 3, isLast: true, data: Array(repeating: 1, count: 8)))
        XCTAssertEqual(first?.name, nameA)

        transfers.offer(FileOffer(transferID: 4, name: nameB, size: 8))
        XCTAssertNil(transfers.chunk(FileChunk(transferID: 4, isLast: true, data: Array(repeating: 1, count: 8))))
        XCTAssertTrue(fileExists(named: nameA))
        XCTAssertFalse(fileExists(named: nameB))
    }

    func testUnderCapTransferStillCompletes() throws {
        let name = "ok-\(UUID().uuidString).txt"
        let transfers = IncomingFileTransfers(maxFileSize: 1000, maxSessionSize: 1000)

        transfers.offer(FileOffer(transferID: 2, name: name, size: 5))
        XCTAssertNil(transfers.chunk(FileChunk(transferID: 2, isLast: false, data: Array("hel".utf8))))
        let done = transfers.chunk(FileChunk(transferID: 2, isLast: true, data: Array("lo".utf8)))
        XCTAssertEqual(done?.name, name)
        let data = try XCTUnwrap(done.flatMap { try? Data(contentsOf: $0.url) })
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "hello")
    }

    func testDefaultCapsMatchHostDefaults() {
        XCTAssertEqual(IncomingFileTransfers.defaultMaxFileSize, 2 * 1024 * 1024 * 1024)
        XCTAssertEqual(IncomingFileTransfers.defaultMaxSessionSize, 8 * 1024 * 1024 * 1024)
    }
}

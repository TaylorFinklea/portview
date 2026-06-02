import Foundation
import PortviewProtocol

/// Receives files pushed from the client (a `FileOffer` then ordered `FileChunk`s) and writes
/// them into ~/Downloads, de-duplicating the filename. Tracks one in-flight transfer per id.
final class FileReceiver {
    private struct Transfer {
        let handle: FileHandle
        let url: URL
        var received: UInt64
    }
    private var transfers: [UInt32: Transfer] = [:]
    private let directory: URL

    init() {
        directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    func offer(_ offer: FileOffer) {
        let url = uniqueURL(for: offer.name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            print("file transfer: could not open \(url.path) for writing")
            return
        }
        transfers[offer.transferID] = Transfer(handle: handle, url: url, received: 0)
        print("Receiving \"\(offer.name)\" (\(offer.size) bytes) → \(url.path)")
    }

    func chunk(_ chunk: FileChunk) {
        guard var transfer = transfers[chunk.transferID] else { return }
        if !chunk.data.isEmpty {
            try? transfer.handle.write(contentsOf: Data(chunk.data))
            transfer.received += UInt64(chunk.data.count)
            transfers[chunk.transferID] = transfer
        }
        if chunk.isLast {
            try? transfer.handle.close()
            transfers[chunk.transferID] = nil
            print("Saved \(transfer.url.lastPathComponent) (\(transfer.received) bytes).")
        }
    }

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

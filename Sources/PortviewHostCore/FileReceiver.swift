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
    }
    private var transfers: [UInt32: Transfer] = [:]
    private let directory: URL
    private let maxFileSize: UInt64
    private let maxSessionSize: UInt64
    private var sessionTotal: UInt64 = 0

    init(
        directory: URL? = nil,
        maxFileSize: UInt64 = FileReceiver.defaultMaxFileSize,
        maxSessionSize: UInt64 = FileReceiver.defaultMaxSessionSize
    ) {
        self.directory = directory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        self.maxFileSize = maxFileSize
        self.maxSessionSize = maxSessionSize
    }

    func offer(_ offer: FileOffer) {
        let url = uniqueURL(for: offer.name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            logger.error("file transfer: could not open \(url.path) for writing")
            return
        }
        transfers[offer.transferID] = Transfer(handle: handle, url: url, received: 0)
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
            try? transfer.handle.write(contentsOf: Data(chunk.data))
            transfer.received += incoming
            sessionTotal += incoming
            transfers[chunk.transferID] = transfer
        }
        if chunk.isLast {
            try? transfer.handle.close()
            transfers[chunk.transferID] = nil
            logger.info("Saved \(transfer.url.lastPathComponent) (\(transfer.received, privacy: .public) bytes).")
        }
    }

    /// Over the per-file or per-session cap: close the handle, delete the partial file, and drop
    /// the transfer (no further chunks for this id will be written).
    private func dropTransfer(_ transferID: UInt32, _ transfer: Transfer) {
        try? transfer.handle.close()
        try? FileManager.default.removeItem(at: transfer.url)
        transfers[transferID] = nil
        logger.warning("file transfer: \(transfer.url.lastPathComponent) exceeded size cap, dropped.")
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

import Foundation
import PortviewProtocol

/// A fully-received Mac→iPhone file, written to a temp URL and ready to share/save.
struct ReceivedFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let name: String
}

/// Assembles inbound Mac→iPhone file transfers (`FileOffer` + ordered `FileChunk`s), streaming each
/// chunk straight to disk so the whole file never sits in memory (bounded to one chunk on the
/// memory-constrained iPhone). Each transfer gets its own temp subdirectory, so same-named files
/// never alias. The peer-supplied name is sanitized at offer time (path-traversal defense).
final class IncomingFileTransfers {
    /// Per-transfer cap. `offer.size` is host-reported and untrusted, so this bounds actual
    /// bytes written regardless of what the offer claims.
    static let defaultMaxFileSize: UInt64 = 2 * 1024 * 1024 * 1024 // 2 GiB
    /// Total bytes writable across all transfers for the lifetime of this assembler (one per
    /// session), independent of the per-file cap.
    static let defaultMaxSessionSize: UInt64 = 8 * 1024 * 1024 * 1024 // 8 GiB

    private struct Transfer {
        let url: URL
        let handle: FileHandle
        let name: String
        var received: UInt64
    }

    private var inProgress: [UInt32: Transfer] = [:]
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("PortviewIncoming", isDirectory: true)
    private let maxFileSize: UInt64
    private let maxSessionSize: UInt64
    private var sessionTotal: UInt64 = 0

    init(
        maxFileSize: UInt64 = IncomingFileTransfers.defaultMaxFileSize,
        maxSessionSize: UInt64 = IncomingFileTransfers.defaultMaxSessionSize
    ) {
        self.maxFileSize = maxFileSize
        self.maxSessionSize = maxSessionSize
    }

    /// Begin receiving an offered file. Returns the sanitized name, or nil if the name is unsafe or
    /// the destination couldn't be opened (the transfer is then ignored).
    @discardableResult
    func offer(_ offer: FileOffer) -> String? {
        guard let safeName = Self.safeFilename(offer.name) else { return nil }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(safeName)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        inProgress[offer.transferID] = Transfer(url: url, handle: handle, name: safeName, received: 0)
        return safeName
    }

    /// Append a chunk to its on-disk file; returns the completed file on the last chunk, else nil.
    /// A chunk pushing the transfer over the per-file or per-session cap drops the transfer and
    /// deletes its partial file (caps count actual bytes written — `offer.size` is untrusted).
    func chunk(_ chunk: FileChunk) -> ReceivedFile? {
        guard var transfer = inProgress[chunk.transferID] else { return nil }
        if !chunk.data.isEmpty {
            let incoming = UInt64(chunk.data.count)
            if transfer.received + incoming > maxFileSize || sessionTotal + incoming > maxSessionSize {
                dropTransfer(chunk.transferID, transfer)
                return nil
            }
            try? transfer.handle.write(contentsOf: Data(chunk.data))
            transfer.received += incoming
            sessionTotal += incoming
            inProgress[chunk.transferID] = transfer
        }
        guard chunk.isLast else { return nil }
        try? transfer.handle.close()
        inProgress[chunk.transferID] = nil
        return ReceivedFile(url: transfer.url, name: transfer.name)
    }

    /// Over the per-file or per-session cap: close the handle, delete the partial file, and drop
    /// the transfer (no further chunks for this id will be written).
    private func dropTransfer(_ transferID: UInt32, _ transfer: Transfer) {
        try? transfer.handle.close()
        try? FileManager.default.removeItem(at: transfer.url)
        inProgress[transferID] = nil
    }

    /// Abandon any in-progress transfers (closes their handles) — e.g. between sessions.
    func removeAll() {
        for transfer in inProgress.values { try? transfer.handle.close() }
        inProgress.removeAll()
    }

    /// Sanitize a peer-supplied filename to a safe last path component (defends against path
    /// traversal — the host is cert-pinned but its filenames are still untrusted input). Returns nil
    /// for the traversal tokens / empty names.
    static func safeFilename(_ name: String) -> String? {
        let base = (name as NSString).lastPathComponent
        guard !base.isEmpty, base != ".", base != ".." else { return nil }
        return base
    }
}

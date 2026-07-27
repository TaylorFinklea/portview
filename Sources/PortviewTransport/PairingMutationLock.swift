// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
@_silgen_name("flock")
private func systemFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

protocol PairingMutationLock: Sendable {
    func acquire() throws -> Int32
    func release(_ token: Int32)
}

struct NoopPairingMutationLock: PairingMutationLock {
    func acquire() throws -> Int32 { -1 }
    func release(_ token: Int32) {}
}

struct FilePairingMutationLock: PairingMutationLock {
    private let url: URL
    private let timeout: TimeInterval

    init(url: URL, timeout: TimeInterval = 2) {
        self.url = url
        self.timeout = timeout
    }

    static var canonical: FilePairingMutationLock {
        let directory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/Portview", isDirectory: true)
        return FilePairingMutationLock(url: directory.appendingPathComponent("pairings.mutation.lock"))
    }

    func acquire() throws -> Int32 {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw PairingStoreError.mutationLockUnavailable(reason: "create directory: \(error)")
        }

        let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw PairingStoreError.mutationLockUnavailable(reason: "open errno \(errno)")
        }

        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(max(0, timeout) * 1_000_000_000)
        var delayMicroseconds: useconds_t = 10_000
        while true {
            if systemFlock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                return descriptor
            }
            let lockError = errno
            if lockError == EINTR { continue }
            guard lockError == EWOULDBLOCK || lockError == EAGAIN else {
                Darwin.close(descriptor)
                throw PairingStoreError.mutationLockUnavailable(reason: "flock errno \(lockError)")
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                Darwin.close(descriptor)
                throw PairingStoreError.mutationLockUnavailable(reason: "timed out after \(timeout) seconds")
            }
            usleep(delayMicroseconds)
            delayMicroseconds = min(delayMicroseconds + 10_000, 100_000)
        }
    }

    func release(_ token: Int32) {
        guard token >= 0 else { return }
        while systemFlock(token, LOCK_UN) != 0 && errno == EINTR {}
        Darwin.close(token)
    }
}

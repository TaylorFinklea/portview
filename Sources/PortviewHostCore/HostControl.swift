import Foundation
import PortviewProtocol
import PortviewTransport

/// A thread-safe registry of active client connections so the host UI can disconnect them without
/// tearing down the listener (which would otherwise churn the bound port and break saved pairings).
public final class HostControl: @unchecked Sendable {
    private struct Session {
        let connection: PortviewConnection
        /// The session's ordered outbound lane (owned by its serve loop): broadcast/file sends
        /// enqueue here so they order with the session's other outbound traffic and stop at its
        /// teardown, instead of racing as detached per-send Tasks.
        let outbound: OutboundLane<AnyMessage>
    }

    private let lock = NSLock()
    private var sessions: [String: Session] = [:]
    /// Holds a system keep-awake assertion while >=1 client is connected, so the Mac doesn't idle-sleep
    /// or idle-lock mid-session. Keyed by session id (see KeepAwake) so it survives `disconnectAll`.
    private let keepAwake: KeepAwake

    public init() {
        self.keepAwake = KeepAwake(backend: IOKitKeepAwakeBackend())
    }

    /// Test seam: inject a fake keep-awake backend.
    init(keepAwake: KeepAwake) {
        self.keepAwake = keepAwake
    }

    func register(_ id: String, _ connection: PortviewConnection, outbound: OutboundLane<AnyMessage>) {
        lock.lock()
        sessions[id] = Session(connection: connection, outbound: outbound)
        lock.unlock()
        keepAwake.sessionBegan(id)
    }

    func deregister(_ id: String) {
        lock.lock()
        sessions[id] = nil
        lock.unlock()
        keepAwake.sessionEnded(id)
    }

    /// Send a file to the connected iPhone (Mac→iPhone transfer): an offer then ordered 64 KB
    /// chunks, interleaved with the live stream over the same connection.
    public func sendFile(name: String, data: Data, to sessionID: String) {
        lock.lock()
        let session = sessions[sessionID]
        lock.unlock()
        guard let session else { return }
        let transferID = UInt32.random(in: 1...UInt32.max)
        // Back-pressured feeding via the lane's awaitable send: at most ONE chunk sits in the
        // queue at a time, so a large transfer can't head-of-line block control messages (lock
        // status, clipboard, cursor) behind thousands of queued chunks, memory stays ~one chunk
        // beyond the file bytes, and the byte slicing happens off the caller's (main) thread.
        // The Task self-terminates when the session lane finishes: every awaited send resumes
        // immediately and subsequent sends no-op.
        Task {
            let bytes = [UInt8](data)
            await session.outbound.send(.fileOffer(FileOffer(transferID: transferID, name: name, size: UInt64(bytes.count))))
            let chunkSize = 64 * 1024
            var offset = 0
            repeat {
                let end = min(offset + chunkSize, bytes.count)
                let isLast = end >= bytes.count
                await session.outbound.send(.fileChunk(FileChunk(transferID: transferID, isLast: isLast, data: Array(bytes[offset..<end]))))
                offset = end
            } while offset < bytes.count
        }
    }

    /// Send a message to every active client session (e.g. a `DisplaysUpdate` when the host's display
    /// configuration changes). Best-effort, ordered per session via its outbound lane.
    public func broadcast(_ message: AnyMessage) {
        lock.lock()
        let active = Array(sessions.values)
        lock.unlock()
        for session in active {
            session.outbound.enqueue(message)
        }
    }

    /// Close every active client session. The listener stays up and keeps advertising, so we first
    /// send a graceful `bye` (and let it flush) — the client treats that as a deliberate close and
    /// will NOT auto-reconnect, whereas a bare close looks like a network drop and would re-bind.
    public func disconnectAll() {
        lock.lock()
        let active = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        keepAwake.endAll()
        // Deliberately NOT via the outbound lane: this is the teardown path itself — the close must
        // sequence after the bye's send completes, and the lane (whose owner is being torn down)
        // offers no completion hook.
        for session in active {
            Task {
                try? await session.connection.send(.bye(Bye(reason: "Disconnected by host")))
                session.connection.close()
            }
        }
    }
}

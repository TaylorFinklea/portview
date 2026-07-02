import Foundation
import PortviewProtocol
import PortviewTransport

/// A thread-safe registry of active client connections so the host UI can disconnect them without
/// tearing down the listener (which would otherwise churn the bound port and break saved pairings).
public final class HostControl: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [String: PortviewConnection] = [:]
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

    func register(_ id: String, _ connection: PortviewConnection) {
        lock.lock()
        connections[id] = connection
        lock.unlock()
        keepAwake.sessionBegan(id)
    }

    func deregister(_ id: String) {
        lock.lock()
        connections[id] = nil
        lock.unlock()
        keepAwake.sessionEnded(id)
    }

    /// Send a file to the connected iPhone (Mac→iPhone transfer): an offer then ordered 64 KB
    /// chunks, interleaved with the live stream over the same connection.
    public func sendFile(name: String, data: Data, to sessionID: String) {
        lock.lock()
        let connection = connections[sessionID]
        lock.unlock()
        guard let connection else { return }
        let bytes = [UInt8](data)
        let transferID = UInt32.random(in: 1...UInt32.max)
        Task {
            try? await connection.send(.fileOffer(FileOffer(transferID: transferID, name: name, size: UInt64(bytes.count))))
            let chunkSize = 64 * 1024
            var offset = 0
            repeat {
                let end = min(offset + chunkSize, bytes.count)
                let isLast = end >= bytes.count
                try? await connection.send(.fileChunk(FileChunk(transferID: transferID, isLast: isLast, data: Array(bytes[offset..<end]))))
                offset = end
            } while offset < bytes.count
        }
    }

    /// Send a message to every active client session (e.g. a `DisplaysUpdate` when the host's display
    /// configuration changes). Best-effort and fire-and-forget, per connection.
    public func broadcast(_ message: AnyMessage) {
        lock.lock()
        let active = Array(connections.values)
        lock.unlock()
        for connection in active {
            Task { try? await connection.send(message) }
        }
    }

    /// Close every active client session. The listener stays up and keeps advertising, so we first
    /// send a graceful `bye` (and let it flush) — the client treats that as a deliberate close and
    /// will NOT auto-reconnect, whereas a bare close looks like a network drop and would re-bind.
    public func disconnectAll() {
        lock.lock()
        let active = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        keepAwake.endAll()
        for connection in active {
            Task {
                try? await connection.send(.bye(Bye(reason: "Disconnected by host")))
                connection.close()
            }
        }
    }
}

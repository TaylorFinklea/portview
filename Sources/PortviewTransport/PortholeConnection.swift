import Foundation
import Network
import PortviewProtocol

/// Thrown when a connection doesn't become `.ready` within the connect deadline. An unreachable
/// endpoint (no route, or nothing listening) parks `NWConnection` in `.waiting` — retrying, never
/// `.ready`, never `.failed` — so without the deadline `connect` would hang forever.
public struct ConnectTimeoutError: Error {}

/// One Portview session over a secure connection.
///
/// Transport: framed messages travel over a single bidirectional connection. The default is now
/// **QUIC** (TLS 1.3 over UDP) via `connectQUIC` / `PortviewListener(quicIdentity:)`; TLS-over-TCP
/// (`connect` / `PortviewListener(identity:)`) is kept as a fallback. `PortviewConnection` is
/// transport-agnostic — it just send/receives framed bytes over an `NWConnection`, so the choice is
/// purely which `NWParameters` the endpoint is built with. A bare QUIC `NWConnection` is one
/// bidirectional stream (an empirical loopback sweep confirmed it carries a full bidirectional
/// round-trip — no `NWConnectionGroup` needed); lane-splitting into per-frame unidirectional
/// streams is future work.
public final class PortviewConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var decoder = FrameDecoder()
    /// Two-lane bounded buffer behind `inbound` (internal so tests can observe its bounds).
    let inboundBuffer: InboundBuffer

    /// Messages received from the peer. Control messages arrive lossless and in order; video
    /// frames coalesce to the newest two when the consumer falls behind (the drops surface as
    /// sequence gaps in the client's diagnostics). When buffered control payload crosses the
    /// buffer's high water, the receive loop pauses so the transport's flow control pushes back
    /// on the peer; it resumes once this stream is drained below the low water.
    public let inbound: AsyncStream<AnyMessage>

    /// The live connection's resolved remote endpoint (a `.hostPort` once the path is up), so a
    /// discovered/paired Mac can be remembered with a concrete IP and a saved Mac's IP can be
    /// refreshed after it moves. Nil until the path resolves.
    public var resolvedRemoteEndpoint: NWEndpoint? { connection.currentPath?.remoteEndpoint }

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
        let buffer = InboundBuffer()
        self.inboundBuffer = buffer
        self.inbound = AsyncStream(unfolding: { await buffer.next() })
        buffer.setOnResumeReceive { [weak self] in
            guard let self else { return }
            self.queue.async { self.receiveNext() }
        }
    }

    /// Connect over QUIC (the default). A bare QUIC `NWConnection` is a single bidirectional stream;
    /// the handshake fails unless the host presents exactly `pinnedCertificateSHA256`. (QUIC's
    /// server-side double-delivery — `newConnectionHandler` firing twice — is tolerated by the
    /// listener serving each accepted connection concurrently; only the data-carrying one runs a session.)
    public static func connectQUIC(to endpoint: NWEndpoint, pinnedCertificateSHA256: Data) async throws -> PortviewConnection {
        try await connect(to: endpoint, parameters: QUICParameters.client(pinnedCertificateSHA256: pinnedCertificateSHA256))
    }

    /// Connect over TLS-over-TCP (fallback). Certificate pinning is enforced identically.
    public static func connect(to endpoint: NWEndpoint, pinnedCertificateSHA256: Data) async throws -> PortviewConnection {
        try await connect(to: endpoint, parameters: TLSParameters.client(pinnedCertificateSHA256: pinnedCertificateSHA256))
    }

    /// Connect the SAS pairing PREAMBLE over QUIC with an UNPINNED, cert-capturing handshake (TOFU),
    /// returning the connection and the leaf-cert SHA-256 actually presented. This connection carries
    /// ONLY the SAS commit/reveal messages and is torn down before the pinned streaming re-dial; trust
    /// is established by the SAS code, not the handshake. See `SASPreamblePinning`.
    public static func connectCapturingCert(to endpoint: NWEndpoint) async throws -> (PortviewConnection, Data) {
        let (parameters, capture) = QUICParameters.clientCapturingCert()
        let connection = try await connect(to: endpoint, parameters: parameters)
        guard let leafSHA256 = capture.leafSHA256 else {
            connection.close()
            throw SASPreambleError.certNotCaptured
        }
        return (connection, leafSHA256)
    }

    /// Default bound on how long `connect` waits for a connection to become `.ready`. Comfortably
    /// under the client's 30s reconnect window, so an unreachable host fails fast enough to retry.
    static let connectTimeout: Duration = .seconds(10)

    /// `internal` (not `private`) so tests can drive the connect path with a short injected
    /// `timeout` against an unreachable endpoint.
    static func connect(to endpoint: NWEndpoint, parameters: NWParameters,
                        timeout: Duration = connectTimeout) async throws -> PortviewConnection {
        let queue = DispatchQueue(label: "portview.connection")
        let nw = NWConnection(to: endpoint, using: parameters)
        let connection = PortviewConnection(connection: nw, queue: queue)
        try await connection.awaitReady(timeout: timeout)
        connection.startReceiveLoop()
        return connection
    }

    /// Send a message to the peer.
    public func send(_ message: AnyMessage) async throws {
        let bytes = Frame.encodeAny(message)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    /// Cancel the connection and finish the inbound stream.
    public func close() {
        connection.cancel()
        inboundBuffer.finish()
    }

    // MARK: - Internal

    /// Race `awaitReady()` against `timeout`, throwing `ConnectTimeoutError` if the connection
    /// isn't `.ready` in time. `.waiting`/`.preparing` never resume `awaitReady()` on their own
    /// (an unreachable host parks in `.waiting`, retrying forever), so the deadline uses
    /// cancellation — `awaitReady()`'s designed escape hatch — to cancel the wedged connection
    /// and bound every connect.
    private func awaitReady(timeout: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.awaitReady() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ConnectTimeoutError()
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    /// Start the connection and resume once it is ready (or throw on failure). Cancellable:
    /// if the awaiting task is cancelled (e.g. a connect timeout), the connection is cancelled,
    /// which fires `.cancelled` and resumes the continuation — so this can never hang forever.
    private func awaitReady() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        self?.connection.stateUpdateHandler = nil
                        cont.resume()
                    case .failed(let error):
                        self?.connection.stateUpdateHandler = nil
                        cont.resume(throwing: error)
                    case .cancelled:
                        self?.connection.stateUpdateHandler = nil
                        cont.resume(throwing: CancellationError())
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// Begin the continuous receive loop, decoding frames into `inbound`.
    func startReceiveLoop() {
        receiveNext()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            // Re-arm strictly from THIS ingest's verdict, never a re-read of the pause flag:
            // the consumer may clear the pause (dispatching its own re-arm) concurrently, and a
            // re-read that races it would arm the receive loop twice.
            var pauseReceive = false
            if let data, !data.isEmpty {
                switch self.ingest([UInt8](data)) {
                case .fatal: return
                case .ok(let paused): pauseReceive = paused
                }
            }
            if isComplete || error != nil {
                self.inboundBuffer.finish()
                return
            }
            if !pauseReceive { self.receiveNext() }
        }
    }

    private enum IngestResult {
        case fatal
        case ok(pauseReceive: Bool)
    }

    /// Decode `bytes` into the two-lane buffer. `.fatal` means a known-tag frame's body was
    /// malformed and the inbound stream has already been finished (mirroring the
    /// isComplete/error path) instead of silently stalling on the swallowed decode error.
    private func ingest(_ bytes: [UInt8]) -> IngestResult {
        do {
            let messages = try decoder.push(bytes)
            return .ok(pauseReceive: inboundBuffer.enqueue(messages))
        } catch {
            inboundBuffer.finish()
            return .fatal
        }
    }

    /// Test seam preserving the pre-buffer contract: `false` = fatal decode error (the inbound
    /// stream is already finished). Exposed (internal) so tests can drive decode + buffering
    /// without a live socket.
    func processIncoming(_ bytes: [UInt8]) -> Bool {
        if case .fatal = ingest(bytes) { return false }
        return true
    }
}

/// Errors surfaced by `PortviewListener.start()` beyond the underlying `NWError`s.
public enum PortviewListenerError: Error {
    /// The listener reported `.ready` without a bound port — nothing routable to advertise.
    case noBoundPort
}

/// Accepts incoming Portview QUIC connections (host side).
public final class PortviewListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    private let connectionContinuation: AsyncStream<PortviewConnection>.Continuation
    /// Guards the cancel-before-start dead zone: `NWListener` delivers NO state callback (not
    /// even `.cancelled`) when `start(queue:)` follows `cancel()`, so `start()` must observe a
    /// prior cancel itself. The lock orders the flag against `listener.start(queue:)` so a
    /// concurrent `cancel()` either sets the flag before `start()` checks it, or lands on a
    /// started listener (which fires `.cancelled` through the state handler).
    private let startLock = NSLock()
    private var cancelled = false

    /// Incoming connections, each a ready `PortviewConnection`.
    public let connections: AsyncStream<PortviewConnection>

    /// TLS-over-TCP listener (the default/POC transport). `port` binds a specific port (for a
    /// stable, restart-surviving endpoint); `nil` lets the OS assign an ephemeral one.
    public convenience init(identity: TLSIdentity, serviceName: String? = nil, port: UInt16? = nil) throws {
        try self.init(parameters: TLSParameters.server(identity: identity), serviceName: serviceName, port: port)
    }

    /// QUIC listener (additive/experimental). Each inbound QUIC stream arrives as a connection.
    /// `port` binds a specific port (stable host endpoint); `nil` = OS-assigned ephemeral port.
    public convenience init(quicIdentity identity: TLSIdentity, serviceName: String? = nil, port: UInt16? = nil) throws {
        try self.init(parameters: QUICParameters.server(identity: identity), serviceName: serviceName, port: port)
    }

    private init(parameters: NWParameters, serviceName: String?, port: UInt16?) throws {
        let queue = DispatchQueue(label: "portview.listener")
        self.queue = queue
        let listener: NWListener
        if let port, let endpointPort = NWEndpoint.Port(rawValue: port) {
            listener = try NWListener(using: parameters, on: endpointPort)
        } else {
            listener = try NWListener(using: parameters)
        }
        if let serviceName {
            listener.service = NWListener.Service(name: serviceName, type: PortviewTransport.bonjourServiceType)
        }
        self.listener = listener
        (self.connections, self.connectionContinuation) = AsyncStream<PortviewConnection>.makeStream()

        let continuation = connectionContinuation
        listener.newConnectionHandler = { nw in
            let connection = PortviewConnection(connection: nw, queue: queue)
            nw.start(queue: queue)
            connection.startReceiveLoop()
            continuation.yield(connection)
        }
    }

    /// Start listening and return the bound port once ready. Every state resolves the
    /// continuation (`.waiting`/`.cancelled`/a nil-port `.ready` previously fell through and
    /// wedged the host run task forever, holding the persisted port), and — mirroring
    /// `awaitReady`'s shape — cancelling the awaiting task cancels the listener, which fires
    /// `.cancelled` and resumes, so this can never hang.
    public func start() async throws -> NWEndpoint.Port {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NWEndpoint.Port, Error>) in
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        self?.listener.stateUpdateHandler = nil
                        if let port = self?.listener.port {
                            cont.resume(returning: port)
                        } else {
                            self?.listener.cancel()
                            cont.resume(throwing: PortviewListenerError.noBoundPort)
                        }
                    case .waiting(let error):
                        // For a listener, `.waiting` means the binding is unavailable (e.g. the
                        // port is taken); it would otherwise park here retrying indefinitely.
                        // Fail fast — `HostRunner.startListener` already falls back to an
                        // OS-assigned port when a preferred-port `start()` throws.
                        self?.listener.stateUpdateHandler = nil
                        self?.listener.cancel()
                        cont.resume(throwing: error)
                    case .failed(let error):
                        self?.listener.stateUpdateHandler = nil
                        cont.resume(throwing: error)
                    case .cancelled:
                        self?.listener.stateUpdateHandler = nil
                        cont.resume(throwing: CancellationError())
                    default:
                        break
                    }
                }
                startLock.lock()
                if cancelled {
                    // Cancel-before-start dead zone: the listener will never fire a state
                    // callback (see `startLock`), so resume here instead of wedging.
                    listener.stateUpdateHandler = nil
                    startLock.unlock()
                    cont.resume(throwing: CancellationError())
                    return
                }
                listener.start(queue: queue)
                startLock.unlock()
            }
        } onCancel: {
            cancel()
        }
    }

    public func cancel() {
        startLock.lock()
        cancelled = true
        listener.cancel()
        startLock.unlock()
        connectionContinuation.finish()
    }
}

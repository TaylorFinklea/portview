import Foundation
import Network
import PortviewProtocol

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
    private let inboundContinuation: AsyncStream<AnyMessage>.Continuation

    /// Messages received from the peer, in arrival order.
    public let inbound: AsyncStream<AnyMessage>

    /// The live connection's resolved remote endpoint (a `.hostPort` once the path is up), so a
    /// discovered/paired Mac can be remembered with a concrete IP and a saved Mac's IP can be
    /// refreshed after it moves. Nil until the path resolves.
    public var resolvedRemoteEndpoint: NWEndpoint? { connection.currentPath?.remoteEndpoint }

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
        (self.inbound, self.inboundContinuation) = AsyncStream<AnyMessage>.makeStream()
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

    private static func connect(to endpoint: NWEndpoint, parameters: NWParameters) async throws -> PortviewConnection {
        let queue = DispatchQueue(label: "portview.connection")
        let nw = NWConnection(to: endpoint, using: parameters)
        let connection = PortviewConnection(connection: nw, queue: queue)
        try await connection.awaitReady()
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
        inboundContinuation.finish()
    }

    // MARK: - Internal

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
            if let data, !data.isEmpty, !self.processIncoming([UInt8](data)) {
                return
            }
            if isComplete || error != nil {
                self.inboundContinuation.finish()
                return
            }
            self.receiveNext()
        }
    }

    /// Decode `bytes` into messages and yield them. Returns `false` if a known-tag frame's
    /// body was malformed, in which case the inbound stream has already been finished
    /// (mirroring the isComplete/error path) instead of silently stalling on the swallowed
    /// decode error. Exposed (internal) so tests can drive it without a live socket.
    func processIncoming(_ bytes: [UInt8]) -> Bool {
        do {
            let messages = try decoder.push(bytes)
            for message in messages { inboundContinuation.yield(message) }
            return true
        } catch {
            inboundContinuation.finish()
            return false
        }
    }
}

/// Accepts incoming Portview QUIC connections (host side).
public final class PortviewListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    private let connectionContinuation: AsyncStream<PortviewConnection>.Continuation

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

    /// Start listening and return the bound port once ready.
    public func start() async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NWEndpoint.Port, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let port = self?.listener.port {
                        self?.listener.stateUpdateHandler = nil
                        cont.resume(returning: port)
                    }
                case .failed(let error):
                    self?.listener.stateUpdateHandler = nil
                    cont.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func cancel() {
        listener.cancel()
        connectionContinuation.finish()
    }
}

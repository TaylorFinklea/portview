import Foundation
import Network
import PortviewProtocol

/// Errors specific to the experimental QUIC multiplex transport.
public enum QUICError: Error {
    case streamUnavailable
}

/// One Portview session over a secure connection.
///
/// POC scope: handshake + video frames travel as framed messages over a single
/// bidirectional TLS-over-TCP connection. The production target is QUIC with the six
/// logical lanes (per-frame unidirectional video streams); this type is transport-agnostic,
/// so that swap touches only the `NWParameters` builder.
public final class PortviewConnection: @unchecked Sendable {
    private let connection: NWConnection
    /// Retained when this connection is a QUIC stream, so the owning QUIC connection
    /// (the multiplex group) stays alive for the stream's lifetime. nil for TLS-over-TCP.
    private let group: NWConnectionGroup?
    private let queue: DispatchQueue
    private var decoder = FrameDecoder()
    private let inboundContinuation: AsyncStream<AnyMessage>.Continuation

    /// Messages received from the peer, in arrival order.
    public let inbound: AsyncStream<AnyMessage>

    init(connection: NWConnection, queue: DispatchQueue, group: NWConnectionGroup? = nil) {
        self.connection = connection
        self.group = group
        self.queue = queue
        (self.inbound, self.inboundContinuation) = AsyncStream<AnyMessage>.makeStream()
    }

    /// Connect to a host endpoint and return a ready connection (client side).
    /// `pinnedCertificateSHA256` is the host's certificate hash (from pairing); the
    /// TLS handshake fails unless the host presents exactly that certificate.
    public static func connect(to endpoint: NWEndpoint, pinnedCertificateSHA256: Data) async throws -> PortviewConnection {
        let queue = DispatchQueue(label: "portview.connection")
        let nw = NWConnection(to: endpoint, using: TLSParameters.client(pinnedCertificateSHA256: pinnedCertificateSHA256))
        let connection = PortviewConnection(connection: nw, queue: queue)
        try await connection.awaitReady()
        connection.startReceiveLoop()
        return connection
    }

    /// Connect over QUIC using the multiplex-group model (additive/experimental — TLS-over-TCP
    /// via `connect(to:)` remains the default). A QUIC connection carries an initial bidirectional
    /// stream, wrapped here as the session transport; the group is retained to keep the QUIC
    /// connection alive. This is the model the bare-`NWConnection` QUIC path couldn't achieve
    /// (it double-delivered connections / hung on reply); see decisions.md.
    public static func connectQUIC(to endpoint: NWEndpoint, pinnedCertificateSHA256: Data) async throws -> PortviewConnection {
        let queue = DispatchQueue(label: "portview.quic.client")
        let descriptor = NWMultiplexGroup(to: endpoint)
        let group = NWConnectionGroup(with: descriptor, using: QUICParameters.client(pinnedCertificateSHA256: pinnedCertificateSHA256))

        // The documented chicken-and-egg: the group does NOT reach `.ready` on its own — opening
        // a stream is what drives the QUIC handshake. So start the group, open the initial
        // bidirectional stream immediately, and wait for the *stream* (not the group) to be ready.
        group.start(queue: queue)
        guard let stream = NWConnection(from: group) else {
            group.cancel()
            throw QUICError.streamUnavailable
        }
        let connection = PortviewConnection(connection: stream, queue: queue, group: group)
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
        group?.cancel()
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
            if let data, !data.isEmpty,
               let messages = try? self.decoder.push([UInt8](data)) {
                for message in messages { self.inboundContinuation.yield(message) }
            }
            if isComplete || error != nil {
                self.inboundContinuation.finish()
                return
            }
            self.receiveNext()
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

    /// TLS-over-TCP listener (the default/POC transport).
    public convenience init(identity: TLSIdentity, serviceName: String? = nil) throws {
        try self.init(parameters: TLSParameters.server(identity: identity), serviceName: serviceName)
    }

    /// QUIC listener (additive/experimental). Each inbound QUIC stream arrives as a connection.
    public convenience init(quicIdentity identity: TLSIdentity, serviceName: String? = nil) throws {
        try self.init(parameters: QUICParameters.server(identity: identity), serviceName: serviceName)
    }

    private init(parameters: NWParameters, serviceName: String?) throws {
        let queue = DispatchQueue(label: "portview.listener")
        self.queue = queue
        let listener = try NWListener(using: parameters)
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

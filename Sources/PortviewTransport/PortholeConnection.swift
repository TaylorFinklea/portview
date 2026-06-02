import Foundation
import Network
import PortviewProtocol

/// One Portview session over a secure connection.
///
/// POC scope: handshake + video frames travel as framed messages over a single
/// bidirectional TLS-over-TCP connection. The production target is QUIC with the six
/// logical lanes (per-frame unidirectional video streams); this type is transport-agnostic,
/// so that swap touches only the `NWParameters` builder.
public final class PortviewConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var decoder = FrameDecoder()
    private let inboundContinuation: AsyncStream<AnyMessage>.Continuation

    /// Messages received from the peer, in arrival order.
    public let inbound: AsyncStream<AnyMessage>

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
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

    /// Start the connection and resume once it is ready (or throw on failure).
    private func awaitReady() async throws {
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

    public init(identity: TLSIdentity, serviceName: String? = nil) throws {
        let queue = DispatchQueue(label: "portview.listener")
        self.queue = queue
        let listener = try NWListener(using: TLSParameters.server(identity: identity))
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

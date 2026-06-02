import Testing
import Foundation
import Network
@testable import PortholeTransport
@testable import PortholeProtocol

private struct TimeoutError: Error {}

/// Run `operation`, failing with `TimeoutError` if it outlasts `duration`.
private func withTimeout<T: Sendable>(
    _ duration: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask { try await Task.sleep(for: duration); throw TimeoutError() }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

@Suite struct LoopbackSpikeTests {
    /// Proves a real QUIC connection on 127.0.0.1 carries one frame-encoded message
    /// end to end. A single `NWConnection` with QUIC options is one bidirectional
    /// stream over a QUIC connection (no multiplex group needed for one stream).
    @Test func quicLoopbackCarriesOneFramedMessage() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let queue = DispatchQueue(label: "porthole.loopback")

        let sent = ClientHello(protocolVersion: 1, deviceID: "SPIKE", deviceName: "Loopback", codecs: [.hevc, .h264])

        // Channel the server uses to hand the decoded message back to the test.
        let (decoded, decodedCont) = AsyncStream<AnyMessage>.makeStream()

        // --- SERVER: each incoming QUIC stream arrives as an NWConnection ---
        let listener = try NWListener(using: QUICParameters.server(identity: identity))
        listener.newConnectionHandler = { conn in
            conn.start(queue: queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                guard let data else { return }
                var decoder = FrameDecoder()
                if let messages = try? decoder.push([UInt8](data)) {
                    for message in messages { decodedCont.yield(message) }
                }
            }
        }

        let port: NWEndpoint.Port = try await withTimeout(.seconds(10)) {
            try await withCheckedThrowingContinuation { cont in
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: if let p = listener.port { cont.resume(returning: p) }
                    case .failed(let error): cont.resume(throwing: error)
                    default: break
                    }
                }
                listener.start(queue: queue)
            }
        }

        // --- CLIENT: a single QUIC connection = one bidirectional stream ---
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let connection = NWConnection(to: endpoint, using: QUICParameters.client())

        try await withTimeout(.seconds(10)) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: cont.resume()
                    case .failed(let error): cont.resume(throwing: error)
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
        }

        connection.send(content: Data(Frame.encode(sent)), completion: .contentProcessed { _ in })

        let result = try await withTimeout(.seconds(10)) {
            for await message in decoded { return message }
            throw TimeoutError()
        }

        connection.cancel()
        listener.cancel()

        #expect(result == .clientHello(sent))
    }
}

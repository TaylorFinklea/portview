// SPDX-License-Identifier: Apache-2.0
import Foundation
import Network
import Security
import PortviewProtocol

// QUIC lane-splitting, transport layer (spec: docs/superpowers/specs/2026-07-01-quic-lane-splitting.md,
// association mechanism per the Phase 0 spike findings appendix): the client opens ONE QUIC tunnel
// (`PortviewTunnel`, an `NWConnectionGroup`) carrying the primary stream plus secondary lane
// streams; the host's multiplexed `PortviewListener` receives each tunnel as an
// `NWConnectionGroup` (native association — peer metadata and stream ids cannot distinguish
// tunnels at a flat listener) and classifies every stream by its first byte. The `LanePreamble`
// session token stays as defense in depth on top of the native association.

/// First-byte stream classifier for the multiplexed (group-mode) host accept path.
///
/// INVARIANT (load-bearing): **no legitimate first frame has `bodyLength <= 6`.** A stream's
/// first byte is either a `Lane` raw value (0...6, the `LanePreamble` lane byte) or the varint
/// `bodyLength` of the stream's first frame — and the smallest legitimate FIRST frames on any
/// stream are `ClientHello` (legacy/new primary handshake; golden first byte = 16,
/// GoldenFrameTests) and `SASClientCommit` (pairing preamble; golden first byte = 33), both
/// comfortably above every `Lane` raw value. So: first byte <= `maxLanePreambleByte` → lane
/// preamble path; otherwise → the existing frame path. A naive "unknown lane byte → close"
/// applied at the accept path WITHOUT this frame-path escape would close first-byte-16 (every
/// old client's primary) and first-byte-33 (SAS pairing) streams, breaking host-new/client-old
/// interop and pairing entirely. Guarded by `LaneStreamClassifierTests`.
enum StreamClassifier {
    /// Largest first byte that classifies as a lane preamble: `Lane`'s maximum raw value.
    static let maxLanePreambleByte: UInt8 = Lane.allCases.map(\.rawValue).max() ?? 0

    enum Classification: Equatable {
        case lanePreamble
        case frame
    }

    static func classify(firstByte: UInt8) -> Classification {
        firstByte <= maxLanePreambleByte ? .lanePreamble : .frame
    }
}

/// Host-minted per-session secret that binds secondary lane streams to their session (defense in
/// depth on top of the tunnel's native grouped delivery). Minted at handshake, carried to the
/// client in `ServerHello.sessionToken`, presented back in every `LanePreamble`.
public enum LaneSessionToken {
    /// Mint a fresh token from the system CSPRNG.
    ///
    /// SECURITY MARKER (deliberate deferral): token COMPARISON on the accept path is a plain
    /// byte-equality lookup, and hygiene (constant-time compare, never-log) is DEFERRED to the
    /// security-review pass per the lane-splitting spec's review fold — do not bolt ad-hoc
    /// hardening on here.
    public static func mint() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: LanePreamble.tokenLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes
    }
}

/// One secondary lane stream bound to an authorized session: the preamble's `Lane` plus a
/// `PortviewConnection` for the stream (its own `FrameDecoder`; frames never straddle streams —
/// see `LanePreamble`). The host sends this lane's frames on `connection`.
public struct AcceptedLane: Sendable {
    public let lane: Lane
    public let connection: PortviewConnection
}

/// Errors surfaced by `PortviewTunnel` stream opens.
public enum PortviewTunnelError: Error {
    /// `NWConnection(from: group)` returned nil — the group isn't started (spike finding: streams
    /// cannot be created before `start(queue:)`).
    case streamOpenFailed
}

/// Thrown when a stream's raw preamble bytes don't arrive within the bounded raw-read deadline.
/// The existing first-message deadline helper (`HostRunner.MessageReader.next(deadline:)`,
/// HandshakeDeadlineTests) operates on decoded `AnyMessage` streams and cannot bound bytes that
/// precede framing — the lane preamble is raw pre-framing bytes, so the accept path gets this
/// transport-layer analogue (slow-loris bound on stream open).
struct LanePreambleDeadlineError: Error {}

/// Resume a continuation exactly once. `NWConnectionGroup` can deliver a second terminal state
/// (`.failed` then `.cancelled`) before an in-handler `stateUpdateHandler = nil` takes effect,
/// which trips SWIFT TASK CONTINUATION MISUSE without this guard (spike finding).
private final class OneShotContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    private func take() -> CheckedContinuation<T, Error>? {
        lock.lock(); defer { lock.unlock() }
        let taken = continuation
        continuation = nil
        return taken
    }
    func resume(returning value: T) { take()?.resume(returning: value) }
    func resume(throwing error: Error) { take()?.resume(throwing: error) }
}

// MARK: - Client side

/// ONE QUIC tunnel multiplexing several streams (client side, `NWConnectionGroup`): the primary
/// stream (the existing single-stream protocol) plus secondary lane streams. One handshake, one
/// cert-pinning evaluation per tunnel (spike-verified — stream opens never re-run verification,
/// so nothing re-pins per stream), shared congestion control; streams are independently ordered,
/// so loss on the video lane no longer stalls input on primary.
public final class PortviewTunnel: @unchecked Sendable {
    private let group: NWConnectionGroup
    private let queue: DispatchQueue

    private init(group: NWConnectionGroup, queue: DispatchQueue) {
        self.group = group
        self.queue = queue
    }

    /// Dial one QUIC tunnel to `endpoint`, pinned to `pinnedCertificateSHA256`, and wait for it
    /// to become ready. Spike gotchas honored: `newConnectionHandler` MUST be installed before
    /// `start(queue:)` (the group otherwise never leaves `.setup`, silently); a transient
    /// `.waiting(ENETDOWN)` can precede `.ready` on loopback, so `.waiting` is never terminal.
    public static func connectQUIC(to endpoint: NWEndpoint, pinnedCertificateSHA256: Data) async throws -> PortviewTunnel {
        let queue = DispatchQueue(label: "portview.tunnel")
        let group = NWConnectionGroup(with: NWMultiplexGroup(to: endpoint),
                                      using: QUICParameters.client(pinnedCertificateSHA256: pinnedCertificateSHA256))
        // Phase 1: the host never opens streams; drop anything peer-initiated. Installed before
        // start(queue:) — required for the group to leave .setup at all.
        group.newConnectionHandler = { $0.cancel() }
        try await startReady(group, queue: queue, timeout: PortviewConnection.connectTimeout)
        return PortviewTunnel(group: group, queue: queue)
    }

    /// Open the primary stream: the existing single-stream protocol (handshake, control, input,
    /// clipboard, SAS, ping/pong, files) rides here unchanged — no preamble.
    public func openPrimaryStream() async throws -> PortviewConnection {
        let connection = try await openStream()
        connection.startReceiveLoop()
        return connection
    }

    /// Open a secondary lane stream: a BIDI stream (a client-opened unidirectional stream could
    /// never carry host→client frames) on which the client writes only the `LanePreamble` —
    /// `sessionToken` is the host-minted token from `ServerHello` — and then stays quiet while
    /// the host sends that lane's frames.
    public func openLane(_ lane: Lane, sessionToken: [UInt8]) async throws -> PortviewConnection {
        let connection = try await openStream()
        try await connection.sendRaw(LanePreamble(lane: lane, sessionToken: sessionToken).encode())
        connection.startReceiveLoop()
        return connection
    }

    /// Open one ready stream on the tunnel, receive loop NOT started. `internal` (not `private`)
    /// so tests can drive raw/partial preamble bytes against the host's classifier.
    func openStream() async throws -> PortviewConnection {
        guard let stream = NWConnection(from: group) else { throw PortviewTunnelError.streamOpenFailed }
        let connection = PortviewConnection(connection: stream, queue: queue)
        try await connection.awaitReady(timeout: PortviewConnection.connectTimeout)
        return connection
    }

    /// Cancel the tunnel (and with it every stream riding on it).
    public func cancel() {
        group.cancel()
    }

    /// Start `group` and resume once ready, racing a timeout — the group analogue of
    /// `PortviewConnection.awaitReady(timeout:)` (cancellation cancels the group, which fires a
    /// terminal state and resumes, so this can never hang).
    private static func startReady(_ group: NWConnectionGroup, queue: DispatchQueue, timeout: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { race in
            race.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        let once = OneShotContinuation(cont)
                        group.stateUpdateHandler = { state in
                            switch state {
                            case .ready:
                                once.resume(returning: ())
                            case .failed(let error):
                                once.resume(throwing: error)
                            case .cancelled:
                                once.resume(throwing: CancellationError())
                            default:
                                break // .waiting is transient on loopback — keep waiting
                            }
                        }
                        group.start(queue: queue)
                    }
                } onCancel: { group.cancel() }
            }
            race.addTask {
                try await Task.sleep(for: timeout)
                throw ConnectTimeoutError()
            }
            defer { race.cancelAll() }
            _ = try await race.next()
        }
        group.stateUpdateHandler = nil
    }
}

// MARK: - Host side

/// Group-mode accept plumbing for `PortviewListener`: owns every live tunnel, classifies each
/// stream by its first byte, routes frame-path streams into the listener's EXISTING `connections`
/// stream (so legacy bare dials — which arrive as single-stream groups — are served unchanged),
/// and binds lane-preamble streams to their tunnel's authorized session.
final class TunnelAccepter: @unchecked Sendable {
    private let queue: DispatchQueue
    private let connections: AsyncStream<PortviewConnection>.Continuation
    /// Bounded raw-read deadline for the whole preamble/classification read (see
    /// `LanePreambleDeadlineError`). Injectable so tests don't wait the production 5s.
    private let preambleDeadline: Duration
    private let lock = NSLock()
    private var tunnels: [ObjectIdentifier: AcceptedTunnel] = [:]
    private var cancelled = false

    init(queue: DispatchQueue, connections: AsyncStream<PortviewConnection>.Continuation,
         preambleDeadline: Duration) {
        self.queue = queue
        self.connections = connections
        self.preambleDeadline = preambleDeadline
    }

    /// Accept one inbound tunnel (every dial arrives here in group mode — a legacy bare
    /// `NWConnection` dial shows up as a single-stream group whose stream classifies down the
    /// frame path).
    func accept(_ group: NWConnectionGroup) {
        let tunnel = AcceptedTunnel(group: group)
        let id = ObjectIdentifier(group)
        lock.lock()
        if cancelled {
            lock.unlock()
            group.cancel()
            return
        }
        tunnels[id] = tunnel
        lock.unlock()
        // Handlers installed BEFORE start (a group silently never leaves .setup otherwise).
        group.newConnectionHandler = { [weak self, weak tunnel] stream in
            guard let self, let tunnel else {
                stream.cancel()
                return
            }
            self.acceptStream(stream, on: tunnel)
        }
        group.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                // Can fire back-to-back (.failed then .cancelled) — removal is idempotent.
                self?.removeTunnel(id)
            default:
                break
            }
        }
        group.start(queue: queue)
    }

    private func removeTunnel(_ id: ObjectIdentifier) {
        lock.lock()
        let tunnel = tunnels.removeValue(forKey: id)
        lock.unlock()
        tunnel?.finishAuthorizations()
    }

    /// Cancel every live tunnel (listener teardown).
    func cancelAll() {
        lock.lock()
        cancelled = true
        let live = tunnels.values
        tunnels.removeAll()
        lock.unlock()
        for tunnel in live {
            tunnel.finishAuthorizations()
            tunnel.group.cancel()
        }
    }

    private func acceptStream(_ stream: NWConnection, on tunnel: AcceptedTunnel) {
        stream.start(queue: queue)
        let queue = queue
        let connections = connections
        let deadline = preambleDeadline
        Task {
            await Self.classifyAndRoute(stream, tunnel: tunnel, queue: queue,
                                        connections: connections, preambleDeadline: deadline)
        }
    }

    /// Classify one inbound stream by its first byte (see `StreamClassifier` for the invariant)
    /// and route it. Every failure closes THIS STREAM ONLY — the tunnel, its primary stream, and
    /// its other lanes are unaffected.
    private static func classifyAndRoute(
        _ stream: NWConnection,
        tunnel: AcceptedTunnel,
        queue: DispatchQueue,
        connections: AsyncStream<PortviewConnection>.Continuation,
        preambleDeadline: Duration
    ) async {
        let preambleLength = 1 + LanePreamble.tokenLength
        do {
            // Never buffer more than one preamble's worth of raw bytes here: classification
            // needs at most `preambleLength` bytes, and anything beyond stays in the transport's
            // (flow-controlled) receive buffer until the stream's own decoder takes over.
            //
            // The FIRST byte is awaited with NO deadline — parked, not policed. The iOS client's
            // tunnel carries an extra stream that never sends a byte, and deadline-cancelling
            // that never-ready stream cascaded "Socket is not connected" through the shared QUIC
            // stack and killed the live session (device session 2026-07-16). A parked zero-byte
            // stream costs nothing (classification is byte-driven, QUIC stream caps bound the
            // count) and dies with its tunnel. The deadline starts at the first byte and bounds
            // the REMAINDER of the preamble — the actual slow-loris surface.
            var (bytes, isComplete) = try await receiveRaw(
                on: stream, minimum: 1, maximum: preambleLength, deadline: nil)
            let deadline = ContinuousClock().now.advanced(by: preambleDeadline)
            guard let firstByte = bytes.first else {
                stream.cancel() // FIN or dead delivery with no bytes
                return
            }

            if StreamClassifier.classify(firstByte: firstByte) == .frame {
                // EXISTING frame path (legacy/new primary, SAS preamble): hand the stream to a
                // `PortviewConnection` exactly as the flat listener does — its own `FrameDecoder`
                // (frames never straddle streams, see `LanePreamble`) seeded with the bytes the
                // classifier already consumed. Frame-path streams remember their tunnel so the
                // host can authorize lanes on it after the handshake (`acceptLanes`).
                let connection = PortviewConnection(connection: stream, queue: queue)
                connection.tunnel = tunnel
                connections.yield(connection)
                connection.adoptClassifiedPrefix(bytes, isComplete: isComplete)
                return
            }

            // Lane path. Per-tunnel cap first: one client (tunnel) gets a bounded number of
            // lane-preamble attempts, so garbage streams can't multiply classify work or lane
            // bindings (the QUIC-level allowance in `QUICParameters` is the coarser backstop).
            guard tunnel.registerLanePathStream() else {
                stream.cancel()
                return
            }
            while bytes.count < preambleLength, !isComplete {
                let more = try await receiveRaw(on: stream, minimum: preambleLength - bytes.count,
                                                maximum: preambleLength - bytes.count, deadline: deadline)
                bytes += more.bytes
                isComplete = more.isComplete
            }
            guard bytes.count >= preambleLength else {
                stream.cancel() // stream FIN'd mid-preamble
                return
            }
            // Unknown lane byte throws here → close THIS stream only (session unaffected).
            let preamble = try LanePreamble.decode(bytes)
            let connection = PortviewConnection(connection: stream, queue: queue)
            // Bad/unauthorized token (secondary streams are accepted only AFTER the primary
            // handshake completes — authorization happens then) or an already-bound duplicate
            // lane → close THIS stream only.
            guard tunnel.bind(preamble, connection: connection) else {
                connection.close()
                return
            }
            connection.startReceiveLoop()
        } catch {
            // Raw-read deadline (slow-loris/stalled preamble), preamble decode error, or
            // transport error: close this stream only.
            stream.cancel()
        }
    }

    /// Raw pre-framing read with an absolute deadline — the transport-layer analogue of the
    /// decoded-message `next(deadline:)` (which cannot apply here: no `FrameDecoder` has seen
    /// this stream yet). On timeout the pending receive is unblocked by cancelling the stream.
    /// `deadline: nil` parks the read indefinitely (the zero-byte first read — see
    /// `classifyAndRoute`); the stream's tunnel dying errors the receive and releases it.
    private static func receiveRaw(
        on stream: NWConnection, minimum: Int, maximum: Int, deadline: ContinuousClock.Instant?
    ) async throws -> (bytes: [UInt8], isComplete: Bool) {
        try await withThrowingTaskGroup(of: (bytes: [UInt8], isComplete: Bool).self) { race in
            race.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(bytes: [UInt8], isComplete: Bool), Error>) in
                        stream.receive(minimumIncompleteLength: minimum, maximumLength: maximum) { data, _, isComplete, error in
                            if let error {
                                cont.resume(throwing: error)
                            } else {
                                cont.resume(returning: (data.map { [UInt8]($0) } ?? [], isComplete))
                            }
                        }
                    }
                } onCancel: { stream.cancel() }
            }
            if let deadline {
                race.addTask {
                    try await Task.sleep(until: deadline, clock: .continuous)
                    throw LanePreambleDeadlineError()
                }
            }
            defer { race.cancelAll() }
            guard let first = try await race.next() else { throw LanePreambleDeadlineError() }
            return first
        }
    }
}

/// One accepted QUIC tunnel (host side, group mode): the association key for every stream riding
/// on it. Tracks the session-token authorizations minted by the host at handshake and the lanes
/// bound under each, and caps how many streams may enter the lane-preamble path.
final class AcceptedTunnel: @unchecked Sendable {
    /// App-level per-tunnel cap on streams entering the lane-preamble path, counted per ATTEMPT
    /// (a garbage preamble burns the tunnel's own budget — the tunnel IS the client). Phase 1
    /// legitimately opens exactly 3; the headroom covers retries without letting one tunnel
    /// multiply classify work.
    static let maxLanePathStreams = 8

    let group: NWConnectionGroup
    private let lock = NSLock()
    private var lanePathStreams = 0
    private var authorizations: [[UInt8]: LaneAuthorization] = [:]

    /// One authorized session token's lane bindings and delivery stream. `@unchecked Sendable`:
    /// `boundLanes` is only touched under the owning tunnel's lock.
    private final class LaneAuthorization: @unchecked Sendable {
        let continuation: AsyncStream<AcceptedLane>.Continuation
        var boundLanes: Set<Lane> = []
        init(continuation: AsyncStream<AcceptedLane>.Continuation) { self.continuation = continuation }
    }

    init(group: NWConnectionGroup) {
        self.group = group
    }

    /// Authorize `sessionToken` for lane binding and return the stream of lanes as they bind.
    /// Called (via `PortviewConnection.acceptLanes`) once the primary handshake completes — never
    /// before, which is what enforces "secondary streams accepted only AFTER the handshake".
    /// When the consumer stops iterating (session teardown), the authorization is revoked, so a
    /// dead session's token can't bind new lanes.
    func authorize(sessionToken: [UInt8]) -> AsyncStream<AcceptedLane> {
        let (stream, continuation) = AsyncStream<AcceptedLane>.makeStream()
        let authorization = LaneAuthorization(continuation: continuation)
        lock.lock()
        let replaced = authorizations[sessionToken]
        authorizations[sessionToken] = authorization
        lock.unlock()
        replaced?.continuation.finish()
        continuation.onTermination = { [weak self, weak authorization] _ in
            self?.revoke(sessionToken: sessionToken, ifStill: authorization)
        }
        return stream
    }

    private func revoke(sessionToken: [UInt8], ifStill authorization: LaneAuthorization?) {
        lock.lock()
        defer { lock.unlock() }
        guard let authorization, authorizations[sessionToken] === authorization else { return }
        authorizations[sessionToken] = nil
    }

    /// Count one stream entering the lane-preamble path; false once the per-tunnel cap is hit.
    func registerLanePathStream() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard lanePathStreams < Self.maxLanePathStreams else { return false }
        lanePathStreams += 1
        return true
    }

    /// Bind a decoded preamble's stream to its authorized session, yielding an `AcceptedLane` to
    /// the authorization's consumer. False (caller closes that stream only) when the token is
    /// unknown/not-yet-authorized or the lane is already bound (a token-holder must not bind N
    /// "video" streams and multiply host send work).
    ///
    /// SECURITY MARKER (deliberate deferral): the token check is a plain byte-equality dictionary
    /// lookup; constant-time compare + never-log hygiene are DEFERRED to the security-review pass
    /// per the lane-splitting spec's review fold.
    func bind(_ preamble: LanePreamble, connection: PortviewConnection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let authorization = authorizations[preamble.sessionToken],
              !authorization.boundLanes.contains(preamble.lane) else {
            return false
        }
        authorization.boundLanes.insert(preamble.lane)
        authorization.continuation.yield(AcceptedLane(lane: preamble.lane, connection: connection))
        return true
    }

    /// Finish every authorization's lane stream (tunnel teardown).
    func finishAuthorizations() {
        lock.lock()
        let live = authorizations.values
        authorizations.removeAll()
        lock.unlock()
        for authorization in live {
            authorization.continuation.finish()
        }
    }
}

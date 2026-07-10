import Foundation
import PortviewProtocol
import PortviewTransport
import os

private let logger = Logger(subsystem: "dev.finklea.portview", category: "lanes")

/// Send seam `HostLaneRouter` routes through: a live `PortviewConnection` in production, a
/// scripted fake in tests.
protocol LaneStreamSender: Sendable {
    func send(_ message: AnyMessage) async throws
}

extension PortviewConnection: LaneStreamSender {}

/// Host-side routing layer of QUIC lane-splitting (bead w6n.4; spec:
/// docs/superpowers/specs/2026-07-01-quic-lane-splitting.md, "Failure modes"): one per session,
/// owned by `serveSession` next to the primary connection. `pumpVideo`'s video/audio/stats sends
/// route through here — onto the client-opened secondary lane stream when one is bound, onto the
/// primary stream otherwise — with stream health checked per send.
///
/// - **Legacy passthrough**: an old-version session (negotiated below
///   `ProtocolVersion.laneVersion`) mints no token and never authorizes lanes, so the router
///   stays in passthrough: every send goes to primary exactly as today and `awaitLaneBindings`
///   returns immediately.
/// - **Lane death**: a failed lane send flips THAT lane back to primary ONCE — logged, no
///   reconnect (the transport's duplicate-lane reject means the lane could never rebind anyway) —
///   and forces an encoder keyframe through the capture's request path. Absorbing the send error
///   to do the flip silently removes the accidental recovery `pumpVideo`'s catch provides (a
///   thrown video send rebuilds the encoder and forces a keyframe), and the first frames sent on
///   primary after a flip are otherwise HEVC deltas referencing frames lost with the lane —
///   frozen video forever — so the router forces the keyframe itself. The errored send is NOT
///   replayed: a replay could land behind newer primary-path frames, and the forced keyframe
///   recovers the loss.
/// - **Never-opening client**: a lane-capable client that never opens its lane streams gets a
///   bounded `laneBindWait`; at the deadline every unbound lane falls back to primary permanently
///   (late binds are ignored) — a session never stalls waiting for streams.
final class HostLaneRouter: @unchecked Sendable {
    /// Bounded wait for a lane-capable client's lane streams to bind before falling back.
    static let laneBindWait: Duration = .seconds(2)
    /// The lanes this router routes — the three phase-1 secondary streams.
    static let routedLanes: Set<Lane> = [.video, .audio, .stats]

    private let lock = NSLock()
    private let primary: any LaneStreamSender
    private let bindWait: Duration
    private var lanes: [Lane: any LaneStreamSender] = [:]
    /// Lanes permanently back on primary: flipped after a send failure, or unbound when the
    /// bounded wait resolved.
    private var fallenBack: Set<Lane> = []
    /// True once `authorizeLanesOnce`'s closure yielded a lane stream — the session may bind lanes.
    private var laneCapable = false
    /// True once `awaitLaneBindings` ran to completion: the lane set is frozen, later binds are
    /// ignored (one fallback decision, no upgrades mid-stream).
    private var resolved = false
    private var authorizeAttempted = false
    private var keyframeRequester: (@Sendable () async -> Void)?

    /// `laneBindWait` is injectable so tests don't wait the production bound.
    init(primary: any LaneStreamSender, laneBindWait: Duration = HostLaneRouter.laneBindWait) {
        self.primary = primary
        self.bindWait = laneBindWait
    }

    /// Run `authorize` (the session's `PortviewConnection.acceptLanes` call) at most ONCE per
    /// router — i.e. once per primary connection. HARD invariant from the w6n.3 review: a repeat
    /// `ClientHello` must NOT re-authorize, because `AcceptedTunnel.authorize` REPLACES the
    /// token's authorization and resets its duplicate-lane protection. Every call after the first
    /// returns nil WITHOUT invoking `authorize`. A nil from `authorize` itself (no tunnel — a
    /// flat/TLS accept, or the tunnel already tore down) leaves the router in legacy passthrough.
    func authorizeLanesOnce(
        _ authorize: () -> AsyncStream<AcceptedLane>?
    ) -> AsyncStream<AcceptedLane>? {
        lock.lock()
        guard !authorizeAttempted else {
            lock.unlock()
            return nil
        }
        authorizeAttempted = true
        lock.unlock()
        guard let laneStream = authorize() else { return nil }
        lock.lock()
        laneCapable = true
        lock.unlock()
        return laneStream
    }

    /// Bind one accepted lane stream. Ignored once the lane set resolved (a late-opening client
    /// stays on primary), after the lane flipped (no reconnect), or for a lane the router never
    /// routes (a client-opened .control/.input/etc stream must not be retained as an inert entry).
    func bind(_ lane: Lane, _ sender: any LaneStreamSender) {
        lock.lock()
        defer { lock.unlock() }
        guard Self.routedLanes.contains(lane),
              laneCapable, !resolved, !fallenBack.contains(lane), lanes[lane] == nil else { return }
        lanes[lane] = sender
    }

    /// Route the keyframe a lane flip forces into the active capture's request path (the same
    /// `consumeKeyframeRequest` plumbing a client `.requestKeyframe` uses). Re-pointed on every
    /// display switch so the request always reaches the live capture.
    func setKeyframeRequester(_ requester: @escaping @Sendable () async -> Void) {
        lock.lock()
        keyframeRequester = requester
        lock.unlock()
    }

    /// Wait (bounded by `laneBindWait`) for the routed lanes to bind, then freeze the lane set:
    /// any still-unbound routed lane falls back to primary permanently. Instant for legacy
    /// sessions and once resolved (each video pump re-enters here, e.g. on a display switch).
    /// Cancellation exits without freezing, so a pump cancelled mid-wait can't lock its
    /// successor out of lanes.
    func awaitLaneBindings() async {
        guard waitingForLanes() else { return }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: bindWait)
        while clock.now < deadline, !Task.isCancelled {
            if allRoutedLanesBound() { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if Task.isCancelled { return }
        let missing = resolveLaneSet()
        if !missing.isEmpty {
            let names = missing.map { "\($0)" }.sorted().joined(separator: ", ")
            logger.notice("lane stream(s) never opened by the client: \(names, privacy: .public); staying on primary for them")
        }
    }

    private func waitingForLanes() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return laneCapable && !resolved
    }

    private func allRoutedLanesBound() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return Self.routedLanes.allSatisfy { lanes[$0] != nil || fallenBack.contains($0) }
    }

    /// Freeze the lane set, falling back every unbound routed lane; returns the lanes that fell.
    private func resolveLaneSet() -> Set<Lane> {
        lock.lock()
        defer { lock.unlock() }
        resolved = true
        let missing = Self.routedLanes.filter { lanes[$0] == nil && !fallenBack.contains($0) }
        fallenBack.formUnion(missing)
        return missing
    }

    /// Send `message` on `lane`'s stream when one is bound, on primary otherwise. Primary-path
    /// errors PROPAGATE — for video frames that keeps `pumpVideo`'s catch (encoder rebuild +
    /// forced keyframe) exactly as today. A lane-path error is absorbed: the lane flips back to
    /// primary once (logged, keyframe forced) and the errored message is NOT replayed.
    func send(_ message: AnyMessage, lane: Lane) async throws {
        guard let sender = boundSender(for: lane) else {
            try await primary.send(message)
            return
        }
        do {
            try await sender.send(message)
        } catch {
            // Flip `lane` back to primary — once: a concurrent second failure on the same lane
            // finds it already flipped and does nothing. The forced keyframe matters for the
            // video lane's HEVC delta chain (see the type doc); for audio/stats flips it is a
            // single harmless keyframe in a rare failure event, kept unconditional so the flip
            // contract stays one rule.
            guard let requestKeyframe = flip(lane) else { return }
            logger.warning("lane \(String(describing: lane), privacy: .public) stream died; falling back to primary (no reconnect): \(error, privacy: .public)")
            await requestKeyframe()
        }
    }

    private func boundSender(for lane: Lane) -> (any LaneStreamSender)? {
        lock.lock()
        defer { lock.unlock() }
        return lanes[lane]
    }

    /// Mark `lane` fallen back. Nil when the lane already flipped (nothing more to do); otherwise
    /// the keyframe request to run — as a no-op closure if none is installed yet, so the flip
    /// itself still happens exactly once.
    private func flip(_ lane: Lane) -> (@Sendable () async -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        guard lanes[lane] != nil else { return nil }
        lanes[lane] = nil
        fallenBack.insert(lane)
        return keyframeRequester ?? {}
    }
}

import Foundation
import Network
import PortviewProtocol
import PortviewTransport

/// Sub-flow for SAS (6-digit) pairing of a Bonjour-discovered Mac, before the pinned session.
public enum SASPairingState: Equatable {
    case connecting          // running the commit/reveal preamble
    case awaitingCode        // preamble done; waiting for the user to type the code shown on the Mac
    case mismatch            // typed code didn't match — possible interception
    case failed(String)      // preamble error
}

/// Owns the client side of SAS (6-digit) pairing: the commit→reveal→derive preamble over an unpinned
/// (TOFU) connection, the held connection across the user-typing phase, and the match/mismatch
/// decision. On a match it sends the authenticated confirm (Guardrail E) on the held peer and asks
/// its owner (via `startPinnedSession`) to re-dial PINNED with the captured cert hash.
@MainActor
public final class SASClientCoordinator {
    /// Non-nil while pairing (drives the entry sheet). Every transition is mirrored to `onStateChange`.
    public private(set) var state: SASPairingState? {
        didSet { onStateChange?(state) }
    }
    /// Bridge for the owner's published state (e.g. `SessionViewModel.sasPairing`).
    public var onStateChange: ((SASPairingState?) -> Void)?
    /// Called on a code match with (endpoint, capturedPinHex, name): the owner re-dials PINNED with
    /// the captured cert hash, so the streaming session is always pin-anchored.
    public var startPinnedSession: ((NWEndpoint, String, String?) -> Void)?

    var derivedCode: String?
    var capturedPinHex: String?
    var endpoint: NWEndpoint?
    var name: String?
    /// The preamble connection is HELD open across the user-typing phase so the client can send an
    /// authenticated `SASClientConfirm` (Guardrail E) on the same peer. Torn down via `teardown`.
    private var connection: PortviewConnection?
    /// Closes the held preamble connection. Captured when the preamble stores `connection`
    /// (production = its `close()`); a settable seam so tests can assert teardown closes it —
    /// mirrors `SessionViewModel.closeConnection`.
    var closeHeldConnection: (() -> Void)?
    /// The secret needed to compute the confirm MAC (zeroed by `teardown`).
    var secret: (clientNonce: [UInt8], hostNonce: [UInt8], cert: [UInt8])?
    private var task: Task<Void, Never>?

    public init() {}

    /// Begin SAS pairing for a Bonjour-discovered Mac (no pin typed). Runs the commit-then-reveal
    /// preamble over an unpinned (TOFU) connection that captures the host's leaf cert, derives the
    /// 6-digit code, and parks awaiting the user to type the code the Mac displays. On a match we
    /// re-dial PINNED with the captured hash (so the streaming session is always pin-anchored).
    public func begin(endpoint: NWEndpoint, name: String) {
        teardown()
        state = .connecting
        self.endpoint = endpoint
        self.name = name
        task?.cancel()
        task = Task { [weak self] in await self?.runPreamble(endpoint: endpoint) }
    }

    private func runPreamble(endpoint: NWEndpoint) async {
        let connection: PortviewConnection
        let capturedHash: Data
        do {
            (connection, capturedHash) = try await PortviewConnection.connectCapturingCert(to: endpoint)
        } catch {
            fail("Couldn't reach the Mac to pair."); return
        }
        self.connection = connection  // stored now so teardown owns its close on every exit
        closeHeldConnection = { connection.close() }
        do {
            let certBytes = [UInt8](capturedHash)
            // Client commits its nonce first (bound to the captured cert + role), before any reveal.
            let clientNonce = SASCode.randomNonce()
            let clientCommit = SASCode.commit(nonce: clientNonce, role: .client, certSHA256: certBytes)
            try await connection.send(.sasClientCommit(SASClientCommit(commit: clientCommit)))

            var inbound = connection.inbound.makeAsyncIterator()
            guard case .sasHostCommit(let hostCommit)? = await inbound.next() else {
                fail("Pairing failed — no response from the Mac."); return
            }
            // Reveal only after the host has committed.
            try await connection.send(.sasClientReveal(SASClientReveal(nonce: clientNonce)))
            guard case .sasHostReveal(let hostReveal)? = await inbound.next() else {
                fail("Pairing failed — the Mac didn't complete the exchange."); return
            }
            guard SASCode.verify(commitment: hostCommit.commit, nonce: hostReveal.nonce,
                                 role: .host, certSHA256: certBytes) else {
                fail("Pairing failed — the Mac's response didn't verify."); return
            }

            let code = SASCode.derive(clientNonce: clientNonce, hostNonce: hostReveal.nonce, certSHA256: certBytes)
            if Task.isCancelled { return }  // cancel() already tore the connection down
            derivedCode = code
            capturedPinHex = capturedHash.map { String(format: "%02x", $0) }.joined()
            secret = (clientNonce, hostReveal.nonce, certBytes)
            state = .awaitingCode  // connection stays open for the confirm
        } catch {
            fail("Couldn't reach the Mac to pair.")
        }
    }

    /// Set an SAS failure state, but never after the user cancelled (which already tore the flow down —
    /// a late write would flash the sheet back). Also releases the held connection.
    private func fail(_ message: String) {
        guard !Task.isCancelled else { return }
        teardown()
        state = .failed(message)
    }

    /// The user typed the code the Mac shows. Match → trust the captured cert → send the confirm on the
    /// held preamble connection, then re-dial PINNED. Mismatch → the captured cert isn't the Mac's
    /// (possible interception) → refuse.
    public func submitCode(_ typed: String) {
        let entered = typed.filter(\.isNumber)
        guard let derived = derivedCode, let pinHex = capturedPinHex, let endpoint else {
            fail("Pairing expired — start again.")
            return
        }
        guard entered == derived else {
            teardown()
            state = .mismatch
            return
        }
        // Match. Capture what we need locally, clear stored state WITHOUT closing (we hold `conn`), then
        // best-effort send the confirm + close on a detached task, then re-dial pinned. Doing the send
        // off the owner's session task means the re-dial's task replacement can't race the in-flight
        // confirm.
        let name = self.name
        let conn = connection
        let secret = self.secret
        teardown(closeConnection: false)
        state = nil
        if let conn, let secret {
            let mac = SASCode.confirmation(clientNonce: secret.clientNonce, hostNonce: secret.hostNonce, certSHA256: secret.cert)
            Task { try? await conn.send(.sasClientConfirm(SASClientConfirm(mac: mac))); conn.close() }
        }
        startPinnedSession?(endpoint, pinHex, name)
    }

    public func cancel() {
        task?.cancel()
        task = nil
        teardown()
        state = nil
    }

    /// The single teardown chokepoint for SAS state: close (unless we hand the connection off) + nil the
    /// held connection, zero the secret, and clear the derived code / pin / endpoint / name. Does NOT
    /// touch `state` — callers set the terminal UI state (.mismatch/.failed/nil) themselves.
    private func teardown(closeConnection: Bool = true) {
        if closeConnection { closeHeldConnection?() }
        closeHeldConnection = nil
        connection = nil
        secret = nil
        derivedCode = nil
        capturedPinHex = nil
        endpoint = nil
        name = nil
    }
}

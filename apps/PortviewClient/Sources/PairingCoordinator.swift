import Foundation
import PortviewTransport

/// Tracks an in-flight pairing until the connection proves it can stream.
@MainActor
final class PairingCoordinator: ObservableObject {
    private(set) var pendingPayload: PairingPayload?

    func markPending(_ payload: PairingPayload) {
        pendingPayload = payload
    }

    func commitIfStreaming(_ isStreaming: Bool, remember: (PairingPayload) -> Void) {
        guard isStreaming, let pendingPayload else { return }
        remember(pendingPayload)
        self.pendingPayload = nil
    }
}

// SPDX-License-Identifier: Apache-2.0
import PortviewHostCore
import PortviewTransport

@main
struct PortviewHostApp {
    static func main() async {
        // The CLI's stdout IS its UI: the ready banner (address/pin/pairing URL), the scannable
        // terminal QR, and the permission help must land in the terminal, not the unified log —
        // the os.Logger sweep covers the PortviewHostCore library (diagnosability inside the
        // GUI-launched .app); a developer running `swift run portview-host` reads the terminal.
        // Legacy-bootstrap until the enrollment ceremony (han.3) exists — see HostAppModel.
        await HostRunner().run(identity: .terminal,
                               authPolicy: .legacyBootstrap(expiresAt: .distantFuture),
                               pairings: PairingStore()) { event in
            switch event {
            case .message(let message):
                print(message)
            case .accessibilityWarning(let message):
                print(message)
            case .failed(let message):
                print(message)
            case .deviceConnected(_, let name):
                print("Device connected: \(name)")
            case .deviceDisconnected:
                print("Device disconnected.")
            case .ready, .sessionStats:
                break
            case .sasCode, .sasConfirmed:
                break  // never print/log the SAS code (secret hygiene); the CLI has no pairing-window UI
            case .enrollmentRequest, .enrollmentResolved:
                // The CLI passes no `enrollment:` authority (nil), so `serveSession` never emits
                // these — a documented limitation, not a bug: `nil` authority means the CLI host
                // only ever admits its existing enrolled devices (`PairingStore` lookups still
                // work); enrolling a NEW device requires the macOS app's Allow/Deny ceremony
                // (`HostAppModel`/`MenuBarHostView`). And because `PairingStore` is a per-process
                // warm cache (han.4 owns the cross-process fix), a long-running CLI process won't
                // see a device the app just enrolled until the CLI is restarted.
                break
            }
        }
    }
}

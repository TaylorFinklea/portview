// SPDX-License-Identifier: Apache-2.0
import PortviewHostCore

@main
struct PortviewHostApp {
    static func main() async {
        // The CLI's stdout IS its UI: the ready banner (address/pin/pairing URL), the scannable
        // terminal QR, and the permission help must land in the terminal, not the unified log —
        // the os.Logger sweep covers the PortviewHostCore library (diagnosability inside the
        // GUI-launched .app); a developer running `swift run portview-host` reads the terminal.
        await HostRunner().run(identity: .terminal) { event in
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
            }
        }
    }
}

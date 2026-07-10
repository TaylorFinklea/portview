// SPDX-License-Identifier: Apache-2.0
import PortviewHostCore
import os

private let logger = Logger(subsystem: "dev.finklea.portview", category: "host")

@main
struct PortviewHostApp {
    static func main() async {
        await HostRunner().run(identity: .terminal) { event in
            switch event {
            case .message(let message):
                logger.info("\(message, privacy: .public)")
            case .accessibilityWarning(let message):
                logger.warning("\(message, privacy: .public)")
            case .failed(let message):
                logger.error("\(message, privacy: .public)")
            case .deviceConnected(_, let name):
                logger.info("device connected: \(name)")
            case .deviceDisconnected:
                logger.info("device disconnected")
            case .ready, .sessionStats:
                break
            case .sasCode, .sasConfirmed:
                break  // never log the SAS code (secret hygiene); the CLI has no pairing-window UI
            }
        }
    }
}

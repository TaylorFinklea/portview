import PortviewHostCore

@main
struct PortviewHostApp {
    static func main() async {
        await HostRunner().run(identity: .terminal) { event in
            switch event {
            case .message(let message), .accessibilityWarning(let message), .failed(let message):
                print(message)
            case .deviceConnected(_, let name):
                print("device connected: \(name)")
            case .deviceDisconnected:
                print("device disconnected")
            case .ready, .sessionStats:
                break
            case .sasCode, .sasConfirmed:
                break  // never log the SAS code (secret hygiene); the CLI has no pairing-window UI
            }
        }
    }
}

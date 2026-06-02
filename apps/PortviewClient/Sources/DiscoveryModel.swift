import Foundation
import PortviewTransport

/// Observes Bonjour for Portview hosts on the LAN and publishes the current set.
@MainActor
final class DiscoveryModel: ObservableObject {
    @Published var hosts: [DiscoveredHost] = []
    private var browser: PortviewBrowser?
    private var task: Task<Void, Never>?

    func start() {
        guard browser == nil else { return }
        let browser = PortviewBrowser()
        self.browser = browser
        browser.start()
        task = Task { [weak self] in
            for await hosts in browser.hosts {
                self?.hosts = hosts
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        browser?.stop()
        browser = nil
        hosts = []
    }
}

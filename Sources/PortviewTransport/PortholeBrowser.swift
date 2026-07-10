// SPDX-License-Identifier: Apache-2.0
import Foundation
import Network

/// A Portview host discovered on the local network via Bonjour.
public struct DiscoveredHost: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let endpoint: NWEndpoint

    public init(id: String, name: String, endpoint: NWEndpoint) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
    }
}

/// Browses the LAN for Portview hosts (Bonjour). Yields the current set on every change.
public final class PortviewBrowser: @unchecked Sendable {
    private let browser: NWBrowser
    private let queue = DispatchQueue(label: "portview.browser")
    private let continuation: AsyncStream<[DiscoveredHost]>.Continuation

    /// The latest discovered host set, re-emitted whenever it changes.
    public let hosts: AsyncStream<[DiscoveredHost]>

    public init() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        browser = NWBrowser(for: .bonjour(type: PortviewTransport.bonjourServiceType, domain: nil), using: parameters)
        (hosts, continuation) = AsyncStream<[DiscoveredHost]>.makeStream()

        let continuation = continuation
        browser.browseResultsChangedHandler = { results, _ in
            let discovered = results.compactMap { result -> DiscoveredHost? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return DiscoveredHost(id: name, name: name, endpoint: result.endpoint)
            }
            continuation.yield(discovered)
        }
    }

    public func start() {
        browser.start(queue: queue)
    }

    public func stop() {
        browser.cancel()
        continuation.finish()
    }
}

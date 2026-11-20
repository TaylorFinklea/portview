// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Immutable snapshot of the user's host preferences that the runtime honors. `nil` means automatic.
public struct HostRuntimePreferences: Equatable, Sendable {
    public var preferredPort: UInt16?
    public var preferredDisplayID: UInt32?

    public init(preferredPort: UInt16? = nil, preferredDisplayID: UInt32? = nil) {
        self.preferredPort = preferredPort
        self.preferredDisplayID = preferredDisplayID
    }

    public static let `default` = HostRuntimePreferences()

    /// The port to bind: the explicit preference, else the identity's last-bound port.
    public func listenerPort(lastBoundPort: UInt16?) -> UInt16? {
        listenerPortCandidates(lastBoundPort: lastBoundPort).first
    }

    /// Ports to try in order — explicit preference first, then the last-bound port (deduplicated).
    /// An OS-assigned port is the caller's final fallback.
    public func listenerPortCandidates(lastBoundPort: UInt16?) -> [UInt16] {
        var result: [UInt16] = []
        for port in [preferredPort, lastBoundPort] {
            if let port, !result.contains(port) { result.append(port) }
        }
        return result
    }

    /// The display a new session starts on: the preferred one when currently available, else the
    /// first available.
    public func initialDisplayID(available: [UInt32]) -> UInt32? {
        if let preferredDisplayID, available.contains(preferredDisplayID) { return preferredDisplayID }
        return available.first
    }

    /// `items` with the preferred display (when present) moved to the front; otherwise unchanged.
    /// The client starts on the first advertised display, so this sets the default display.
    public func orderedDisplays<T>(_ items: [T], id: (T) -> UInt32) -> [T] {
        guard let preferredDisplayID,
              let index = items.firstIndex(where: { id($0) == preferredDisplayID }), index != 0
        else { return items }
        var result = items
        result.insert(result.remove(at: index), at: 0)
        return result
    }
}

/// A live display, published to the app (e.g. for a default-display picker).
public struct HostDisplayDescriptor: Equatable, Sendable {
    public let id: UInt32
    public let width: Int
    public let height: Int

    public init(id: UInt32, width: Int, height: Int) {
        self.id = id
        self.width = width
        self.height = height
    }
}

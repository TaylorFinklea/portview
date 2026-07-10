// SPDX-License-Identifier: Apache-2.0
/// Host → client. The host's screen lock state. When `locked` is true the host's screen is locked
/// (e.g. the screensaver engaged or the user locked it); the captured content is the secure desktop
/// or blank, so the client pauses the live view and shows a "host locked — capture paused" overlay
/// instead of a confusing black frame. Sent only on a state change.
public struct HostLockStatus: WireMessage, Equatable {
    public static let messageType = MessageType.hostLockStatus
    public var locked: Bool

    public init(locked: Bool) { self.locked = locked }

    public func encode(into w: inout BinaryWriter) { w.putBool(locked) }
    public init(from r: inout BinaryReader) throws { locked = try r.bool() }
}

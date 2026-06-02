/// Client → host. Re-target the live video stream to a different display mid-session
/// (without a full reconnect). The id matches a `DisplayInfo.id` from `ServerHello`.
public struct SwitchDisplay: WireMessage, Equatable {
    public static let messageType = MessageType.switchDisplay
    public var displayID: UInt32

    public init(displayID: UInt32) { self.displayID = displayID }

    public func encode(into w: inout BinaryWriter) { w.putUInt32(displayID) }
    public init(from r: inout BinaryReader) throws { displayID = try r.uint32() }
}

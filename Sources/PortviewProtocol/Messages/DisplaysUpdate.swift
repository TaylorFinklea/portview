// SPDX-License-Identifier: Apache-2.0
/// Host → client. Re-advertises the host's available displays mid-session when the display
/// configuration changes (a monitor connected, woke, was removed, or changed resolution). The client
/// refreshes its display list — and thus the display switcher — without a reconnect. Mirrors the
/// `displays` carried in `ServerHello`, but sent on its own whenever the set changes.
public struct DisplaysUpdate: WireMessage, Equatable {
    public static let messageType = MessageType.displaysUpdate
    public var displays: [DisplayInfo]

    public init(displays: [DisplayInfo]) { self.displays = displays }

    public func encode(into w: inout BinaryWriter) {
        w.putVarUInt(UInt64(displays.count))
        for d in displays { d.encode(into: &w) }
    }

    public init(from r: inout BinaryReader) throws {
        let count = try r.varUInt()
        var result: [DisplayInfo] = []
        for _ in 0..<count { result.append(try DisplayInfo(from: &r)) }
        displays = result
    }
}

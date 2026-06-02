/// Host → client. Lists available displays and the codec chosen for this session.
public struct ServerHello: WireMessage {
    public static let messageType = MessageType.serverHello
    public var protocolVersion: UInt16
    public var displays: [DisplayInfo]
    public var chosenCodec: Codec

    public init(protocolVersion: UInt16, displays: [DisplayInfo], chosenCodec: Codec) {
        self.protocolVersion = protocolVersion; self.displays = displays; self.chosenCodec = chosenCodec
    }

    public func encode(into w: inout BinaryWriter) {
        w.putUInt16(protocolVersion)
        w.putVarUInt(UInt64(displays.count))
        for d in displays { d.encode(into: &w) }
        w.putUInt8(chosenCodec.rawValue)
    }

    public init(from r: inout BinaryReader) throws {
        protocolVersion = try r.uint16()
        let count = try r.varUInt()
        var result: [DisplayInfo] = []
        for _ in 0..<count { result.append(try DisplayInfo(from: &r)) }
        displays = result
        let raw = try r.uint8()
        guard let c = Codec(rawValue: raw) else { throw WireError.unknownEnum("Codec", UInt64(raw)) }
        chosenCodec = c
    }
}

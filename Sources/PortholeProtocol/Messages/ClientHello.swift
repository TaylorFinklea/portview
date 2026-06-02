/// Client → host. Opens a session and advertises supported codecs.
public struct ClientHello: WireMessage {
    public static let messageType = MessageType.clientHello
    public var protocolVersion: UInt16
    public var deviceID: String
    public var deviceName: String
    public var codecs: [Codec]

    public init(protocolVersion: UInt16, deviceID: String, deviceName: String, codecs: [Codec]) {
        self.protocolVersion = protocolVersion; self.deviceID = deviceID
        self.deviceName = deviceName; self.codecs = codecs
    }

    public func encode(into w: inout BinaryWriter) {
        w.putUInt16(protocolVersion)
        w.putString(deviceID)
        w.putString(deviceName)
        w.putVarUInt(UInt64(codecs.count))
        for c in codecs { w.putUInt8(c.rawValue) }
    }

    public init(from r: inout BinaryReader) throws {
        protocolVersion = try r.uint16()
        deviceID = try r.string()
        deviceName = try r.string()
        let count = try r.varUInt()
        var result: [Codec] = []
        for _ in 0..<count {
            let raw = try r.uint8()
            guard let c = Codec(rawValue: raw) else { throw WireError.unknownEnum("Codec", UInt64(raw)) }
            result.append(c)
        }
        codecs = result
    }
}

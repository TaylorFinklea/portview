/// Self-delimiting framing: `[varint bodyLength][uint8 messageType][payload]`.
/// `bodyLength` counts the type byte plus the payload.
public enum Frame {
    /// Encode a single message into one frame.
    public static func encode<M: WireMessage>(_ message: M) -> [UInt8] {
        var payload = BinaryWriter()
        message.encode(into: &payload)

        var out = BinaryWriter()
        out.putVarUInt(UInt64(payload.bytes.count + 1)) // +1 for the type byte
        out.putUInt8(M.messageType.rawValue)
        out.putBytes(payload.bytes)
        return out.bytes
    }

    /// Encode whichever concrete message an `AnyMessage` holds.
    public static func encodeAny(_ message: AnyMessage) -> [UInt8] {
        switch message {
        case .clientHello(let m): encode(m)
        case .serverHello(let m): encode(m)
        case .startSession(let m): encode(m)
        case .videoFrame(let m): encode(m)
        case .bye(let m): encode(m)
        case .error(let m): encode(m)
        case .pointerMove(let m): encode(m)
        case .pointerButton(let m): encode(m)
        case .scroll(let m): encode(m)
        case .typeText(let m): encode(m)
        case .keyEvent(let m): encode(m)
        case .cursorPosition(let m): encode(m)
        case .clipboardUpdate(let m): encode(m)
        }
    }

    /// Decode exactly one frame from `bytes` (which must contain a complete frame).
    public static func decode(_ bytes: [UInt8]) throws -> AnyMessage {
        var r = BinaryReader(bytes)
        let bodyLength = try r.varUInt()
        let body = try r.readBytes(Int(bodyLength))
        return try decodeBody(body)
    }

    /// Decode a frame body (`[uint8 messageType][payload]`) into a message.
    static func decodeBody(_ body: [UInt8]) throws -> AnyMessage {
        var r = BinaryReader(body)
        let typeRaw = try r.uint8()
        guard let type = MessageType(rawValue: typeRaw) else {
            throw WireError.unknownMessageType(typeRaw)
        }
        switch type {
        case .clientHello: return .clientHello(try ClientHello(from: &r))
        case .serverHello: return .serverHello(try ServerHello(from: &r))
        case .startSession: return .startSession(try StartSession(from: &r))
        case .videoFrame: return .videoFrame(try VideoFrame(from: &r))
        case .bye: return .bye(try Bye(from: &r))
        case .error: return .error(try ProtocolError(from: &r))
        case .pointerMove: return .pointerMove(try PointerMove(from: &r))
        case .pointerButton: return .pointerButton(try PointerButton(from: &r))
        case .scroll: return .scroll(try Scroll(from: &r))
        case .typeText: return .typeText(try TypeText(from: &r))
        case .keyEvent: return .keyEvent(try KeyEvent(from: &r))
        case .cursorPosition: return .cursorPosition(try CursorPosition(from: &r))
        case .clipboardUpdate: return .clipboardUpdate(try ClipboardUpdate(from: &r))
        }
    }
}

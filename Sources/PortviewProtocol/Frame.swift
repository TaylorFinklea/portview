/// Self-delimiting framing: `[varint bodyLength][uint8 messageType][payload]`.
/// `bodyLength` counts the type byte plus the payload.
public enum Frame {
    /// Largest frame body a peer may declare. Generous headroom over the biggest
    /// legitimate frame (multi-MB HEVC keyframes; 64 KiB file chunks) while bounding
    /// what a malicious length prefix can make the decoder buffer or allocate.
    public static let maxBodyLength: UInt64 = 16 * 1024 * 1024

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
        case .switchDisplay(let m): encode(m)
        case .fileOffer(let m): encode(m)
        case .fileChunk(let m): encode(m)
        case .audioFrame(let m): encode(m)
        case .viewport(let m): encode(m)
        case .qualityStats(let m): encode(m)
        case .sasClientCommit(let m): encode(m)
        case .sasHostCommit(let m): encode(m)
        case .sasClientReveal(let m): encode(m)
        case .sasHostReveal(let m): encode(m)
        case .sasClientConfirm(let m): encode(m)
        case .displaysUpdate(let m): encode(m)
        case .hostLockStatus(let m): encode(m)
        case .ping(let m): encode(m)
        case .pong(let m): encode(m)
        }
    }

    /// Decode exactly one frame from `bytes` (which must contain a complete frame).
    public static func decode(_ bytes: [UInt8]) throws -> AnyMessage {
        var r = BinaryReader(bytes)
        let bodyLength = try r.varUInt()
        guard bodyLength <= maxBodyLength else {
            throw WireError.malformed("frame length exceeds maximum")
        }
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
        case .switchDisplay: return .switchDisplay(try SwitchDisplay(from: &r))
        case .fileOffer: return .fileOffer(try FileOffer(from: &r))
        case .fileChunk: return .fileChunk(try FileChunk(from: &r))
        case .audioFrame: return .audioFrame(try AudioFrame(from: &r))
        case .viewport: return .viewport(try Viewport(from: &r))
        case .qualityStats: return .qualityStats(try QualityStats(from: &r))
        case .sasClientCommit: return .sasClientCommit(try SASClientCommit(from: &r))
        case .sasHostCommit: return .sasHostCommit(try SASHostCommit(from: &r))
        case .sasClientReveal: return .sasClientReveal(try SASClientReveal(from: &r))
        case .sasHostReveal: return .sasHostReveal(try SASHostReveal(from: &r))
        case .sasClientConfirm: return .sasClientConfirm(try SASClientConfirm(from: &r))
        case .displaysUpdate: return .displaysUpdate(try DisplaysUpdate(from: &r))
        case .hostLockStatus: return .hostLockStatus(try HostLockStatus(from: &r))
        case .ping: return .ping(try Ping(from: &r))
        case .pong: return .pong(try Pong(from: &r))
        }
    }
}

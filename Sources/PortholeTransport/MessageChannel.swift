import PortholeProtocol

/// Frames outbound messages and reassembles inbound bytes for a single lane.
/// I/O-free: the QUIC layer feeds it bytes and writes the bytes it produces.
public struct MessageChannel {
    private var decoder = FrameDecoder()
    public init() {}

    /// Encode a message to frame bytes ready to write to the lane's stream.
    public func outbound(_ message: AnyMessage) -> [UInt8] {
        Frame.encodeAny(message)
    }

    /// Feed bytes read from the lane's stream; return any complete messages.
    public mutating func inbound(_ bytes: [UInt8]) throws -> [AnyMessage] {
        try decoder.push(bytes)
    }
}

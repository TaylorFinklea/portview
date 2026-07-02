/// Accumulates a byte stream and yields complete messages as frames arrive.
public struct FrameDecoder {
    private var buffer: [UInt8] = []
    public init() {}

    /// Append `incoming` bytes; return every message that is now fully available.
    public mutating func push(_ incoming: [UInt8]) throws -> [AnyMessage] {
        buffer.append(contentsOf: incoming)
        var messages: [AnyMessage] = []

        while true {
            var reader = BinaryReader(buffer)
            let bodyLength: UInt64
            do {
                bodyLength = try reader.varUInt()
            } catch WireError.truncated {
                break // length prefix not fully arrived yet
            }
            let headerSize = reader.offset
            guard buffer.count - headerSize >= Int(bodyLength) else {
                break // body not fully arrived yet
            }
            let body = Array(buffer[headerSize..<headerSize + Int(bodyLength)])
            do {
                messages.append(try Frame.decodeBody(body))
            } catch WireError.unknownMessageType {
                // Skip this frame: consume it and keep decoding subsequent frames.
            }
            buffer.removeFirst(headerSize + Int(bodyLength))
        }
        return messages
    }
}

// SPDX-License-Identifier: Apache-2.0
/// Accumulates a byte stream and yields complete messages as frames arrive.
public struct FrameDecoder {
    /// Upper bound on bytes retained between pushes: one maximal frame
    /// (10-byte varint header + `Frame.maxBodyLength` body). The per-frame
    /// length guard makes exceeding this unreachable; this backstop keeps the
    /// bound explicit if that guard is ever bypassed or refactored away.
    static let maxBufferedBytes = 10 + Int(Frame.maxBodyLength)

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
            // Compare in UInt64 space BEFORE any Int() conversion: values above
            // Int.max would trap uncatchably, and anything above the ceiling would
            // let a peer make us buffer unbounded memory waiting for the body.
            guard bodyLength <= Frame.maxBodyLength else {
                throw WireError.malformed("frame length exceeds maximum")
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
        guard buffer.count <= Self.maxBufferedBytes else {
            throw WireError.malformed("frame buffer overflow")
        }
        return messages
    }
}

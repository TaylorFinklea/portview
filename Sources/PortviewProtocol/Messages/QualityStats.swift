/// Host → client diagnostics summary. Scaled integer fields keep the wire format deterministic:
/// Mbps/fps/ms values are encoded as value × 100.
public struct QualityStats: WireMessage, Equatable, Sendable {
    public static let messageType = MessageType.qualityStats

    public var displayID: UInt32
    public var encoderWidth: UInt32
    public var encoderHeight: UInt32
    public var configuredBitrate: UInt32
    public var encodedMbpsX100: UInt32
    public var fpsX100: UInt32
    public var averageFrameBytes: UInt32
    public var keyframes: UInt32
    public var averageEncodeMsX100: UInt32
    public var viewportX: UInt16
    public var viewportY: UInt16
    public var viewportW: UInt16
    public var viewportH: UInt16

    public init(
        displayID: UInt32,
        encoderWidth: UInt32,
        encoderHeight: UInt32,
        configuredBitrate: UInt32,
        encodedMbpsX100: UInt32,
        fpsX100: UInt32,
        averageFrameBytes: UInt32,
        keyframes: UInt32,
        averageEncodeMsX100: UInt32,
        viewportX: UInt16,
        viewportY: UInt16,
        viewportW: UInt16,
        viewportH: UInt16
    ) {
        self.displayID = displayID
        self.encoderWidth = encoderWidth
        self.encoderHeight = encoderHeight
        self.configuredBitrate = configuredBitrate
        self.encodedMbpsX100 = encodedMbpsX100
        self.fpsX100 = fpsX100
        self.averageFrameBytes = averageFrameBytes
        self.keyframes = keyframes
        self.averageEncodeMsX100 = averageEncodeMsX100
        self.viewportX = viewportX
        self.viewportY = viewportY
        self.viewportW = viewportW
        self.viewportH = viewportH
    }

    public var encodedMbps: Double { Double(encodedMbpsX100) / 100.0 }
    public var fps: Double { Double(fpsX100) / 100.0 }
    public var averageEncodeMs: Double { Double(averageEncodeMsX100) / 100.0 }
    public var viewportNormalizedX: Double { Double(viewportX) / 65535.0 }
    public var viewportNormalizedY: Double { Double(viewportY) / 65535.0 }
    public var viewportNormalizedW: Double { Double(viewportW) / 65535.0 }
    public var viewportNormalizedH: Double { Double(viewportH) / 65535.0 }

    public func encode(into writer: inout BinaryWriter) {
        writer.putUInt32(displayID)
        writer.putUInt32(encoderWidth)
        writer.putUInt32(encoderHeight)
        writer.putUInt32(configuredBitrate)
        writer.putUInt32(encodedMbpsX100)
        writer.putUInt32(fpsX100)
        writer.putUInt32(averageFrameBytes)
        writer.putUInt32(keyframes)
        writer.putUInt32(averageEncodeMsX100)
        writer.putUInt16(viewportX)
        writer.putUInt16(viewportY)
        writer.putUInt16(viewportW)
        writer.putUInt16(viewportH)
    }

    public init(from reader: inout BinaryReader) throws {
        displayID = try reader.uint32()
        encoderWidth = try reader.uint32()
        encoderHeight = try reader.uint32()
        configuredBitrate = try reader.uint32()
        encodedMbpsX100 = try reader.uint32()
        fpsX100 = try reader.uint32()
        averageFrameBytes = try reader.uint32()
        keyframes = try reader.uint32()
        averageEncodeMsX100 = try reader.uint32()
        viewportX = try reader.uint16()
        viewportY = try reader.uint16()
        viewportW = try reader.uint16()
        viewportH = try reader.uint16()
    }
}

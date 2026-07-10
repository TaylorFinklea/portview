// SPDX-License-Identifier: Apache-2.0
/// Host → client (video lane). One encoded access unit plus its metadata.
public struct VideoFrame: WireMessage, Equatable {
    public static let messageType = MessageType.videoFrame
    public var sequence: UInt64
    public var ptsMicros: UInt64
    public var isKeyframe: Bool
    public var displayID: UInt32
    public var width: UInt32
    public var height: UInt32
    public var viewportX: UInt16
    public var viewportY: UInt16
    public var viewportW: UInt16
    public var viewportH: UInt16
    public var data: [UInt8]

    public init(sequence: UInt64, ptsMicros: UInt64, isKeyframe: Bool, displayID: UInt32, width: UInt32, height: UInt32, data: [UInt8],
                viewportX: UInt16 = 0, viewportY: UInt16 = 0, viewportW: UInt16 = 65535, viewportH: UInt16 = 65535) {
        self.sequence = sequence; self.ptsMicros = ptsMicros; self.isKeyframe = isKeyframe
        self.displayID = displayID; self.width = width; self.height = height; self.data = data
        self.viewportX = viewportX; self.viewportY = viewportY; self.viewportW = viewportW; self.viewportH = viewportH
    }

    /// Convenience init with the viewport expressed as normalized Doubles (0…1).
    public init(sequence: UInt64, ptsMicros: UInt64, isKeyframe: Bool, displayID: UInt32, width: UInt32, height: UInt32, data: [UInt8],
                viewportNormalizedX: Double, viewportNormalizedY: Double, viewportNormalizedW: Double, viewportNormalizedH: Double) {
        let cw = Swift.max(0, Swift.min(1, viewportNormalizedW))
        let ch = Swift.max(0, Swift.min(1, viewportNormalizedH))
        let cx = Swift.max(0, Swift.min(1 - cw, viewportNormalizedX))
        let cy = Swift.max(0, Swift.min(1 - ch, viewportNormalizedY))
        self.init(sequence: sequence, ptsMicros: ptsMicros, isKeyframe: isKeyframe,
                  displayID: displayID, width: width, height: height, data: data,
                  viewportX: UInt16((cx * 65535).rounded()), viewportY: UInt16((cy * 65535).rounded()),
                  viewportW: UInt16((cw * 65535).rounded()), viewportH: UInt16((ch * 65535).rounded()))
    }

    public var normalizedViewportX: Double { Double(viewportX) / 65535.0 }
    public var normalizedViewportY: Double { Double(viewportY) / 65535.0 }
    public var normalizedViewportW: Double { Double(viewportW) / 65535.0 }
    public var normalizedViewportH: Double { Double(viewportH) / 65535.0 }

    public func encode(into w: inout BinaryWriter) {
        w.putUInt64(sequence)
        w.putUInt64(ptsMicros)
        w.putBool(isKeyframe)
        w.putUInt32(displayID)
        w.putUInt32(width)
        w.putUInt32(height)
        w.putUInt16(viewportX)
        w.putUInt16(viewportY)
        w.putUInt16(viewportW)
        w.putUInt16(viewportH)
        w.putData(data)
    }

    public init(from r: inout BinaryReader) throws {
        sequence = try r.uint64()
        ptsMicros = try r.uint64()
        isKeyframe = try r.bool()
        displayID = try r.uint32()
        width = try r.uint32()
        height = try r.uint32()
        viewportX = try r.uint16()
        viewportY = try r.uint16()
        viewportW = try r.uint16()
        viewportH = try r.uint16()
        data = try r.data()
    }
}

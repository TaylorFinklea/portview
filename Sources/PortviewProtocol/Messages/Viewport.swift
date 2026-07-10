// SPDX-License-Identifier: Apache-2.0
/// The visible crop of a display, normalized to 0…65535 (= 0.0…1.0) per axis. Used both ways:
/// client → host requests the host crop its capture to this region (a "magnifier" — the region is
/// then encoded at full resolution, so zoom is crisp instead of upscaled); host → client confirms
/// the region its frames now represent, so the client can render the right residual zoom.
public struct Viewport: WireMessage, Equatable {
    public static let messageType = MessageType.viewport
    public var displayID: UInt32
    public var x: UInt16
    public var y: UInt16
    public var w: UInt16
    public var h: UInt16

    public init(displayID: UInt32, x: UInt16, y: UInt16, w: UInt16, h: UInt16) {
        self.displayID = displayID; self.x = x; self.y = y; self.w = w; self.h = h
    }

    /// Build from normalized doubles (origin + size in 0…1), clamped so the region stays on-screen.
    public init(displayID: UInt32, normalizedX: Double, normalizedY: Double, normalizedW: Double, normalizedH: Double) {
        let cw = Swift.max(0, Swift.min(1, normalizedW))
        let ch = Swift.max(0, Swift.min(1, normalizedH))
        let cx = Swift.max(0, Swift.min(1 - cw, normalizedX))
        let cy = Swift.max(0, Swift.min(1 - ch, normalizedY))
        self.init(displayID: displayID,
                  x: UInt16((cx * 65535).rounded()), y: UInt16((cy * 65535).rounded()),
                  w: UInt16((cw * 65535).rounded()), h: UInt16((ch * 65535).rounded()))
    }

    public var normalizedX: Double { Double(x) / 65535.0 }
    public var normalizedY: Double { Double(y) / 65535.0 }
    public var normalizedW: Double { Double(w) / 65535.0 }
    public var normalizedH: Double { Double(h) / 65535.0 }

    public func encode(into writer: inout BinaryWriter) {
        writer.putUInt32(displayID)
        writer.putUInt16(x)
        writer.putUInt16(y)
        writer.putUInt16(w)
        writer.putUInt16(h)
    }

    public init(from reader: inout BinaryReader) throws {
        displayID = try reader.uint32()
        x = try reader.uint16()
        y = try reader.uint16()
        w = try reader.uint16()
        h = try reader.uint16()
    }
}

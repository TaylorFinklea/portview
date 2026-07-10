// SPDX-License-Identifier: Apache-2.0
/// Appends values to a byte buffer in Portview's wire format.
public struct BinaryWriter: Sendable {
    public private(set) var bytes: [UInt8] = []
    public init() {}

    public mutating func putUInt8(_ v: UInt8) { bytes.append(v) }

    public mutating func putUInt16(_ v: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
        bytes.append(UInt8(truncatingIfNeeded: v))
    }

    public mutating func putUInt32(_ v: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: v >> UInt32(shift)))
        }
    }

    public mutating func putUInt64(_ v: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: v >> UInt64(shift)))
        }
    }

    /// LEB128 unsigned varint.
    public mutating func putVarUInt(_ value: UInt64) {
        var v = value
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while v != 0
    }

    public mutating func putBytes(_ raw: [UInt8]) { bytes.append(contentsOf: raw) }

    /// Length-prefixed (varint count) byte blob.
    public mutating func putData(_ raw: [UInt8]) {
        putVarUInt(UInt64(raw.count))
        bytes.append(contentsOf: raw)
    }

    public mutating func putString(_ s: String) { putData(Array(s.utf8)) }

    public mutating func putBool(_ v: Bool) { putUInt8(v ? 1 : 0) }
}

import Foundation

/// Reads values from a byte buffer in Portview's wire format. Bounds-checked.
public struct BinaryReader: Sendable {
    private let storage: [UInt8]
    public private(set) var offset: Int = 0

    public init(_ bytes: [UInt8]) { self.storage = bytes }
    public init(_ slice: ArraySlice<UInt8>) { self.storage = Array(slice) }

    public var remaining: Int { storage.count - offset }
    public var isAtEnd: Bool { offset >= storage.count }

    public mutating func uint8() throws -> UInt8 {
        guard offset < storage.count else { throw WireError.truncated }
        defer { offset += 1 }
        return storage[offset]
    }

    public mutating func uint16() throws -> UInt16 {
        let hi = try uint8(), lo = try uint8()
        return (UInt16(hi) << 8) | UInt16(lo)
    }

    public mutating func uint32() throws -> UInt32 {
        var v: UInt32 = 0
        for _ in 0..<4 { v = (v << 8) | UInt32(try uint8()) }
        return v
    }

    public mutating func uint64() throws -> UInt64 {
        var v: UInt64 = 0
        for _ in 0..<8 { v = (v << 8) | UInt64(try uint8()) }
        return v
    }

    public mutating func varUInt() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try uint8()
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            if shift >= 64 { throw WireError.malformed("varint too long") }
        }
        return result
    }

    public mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= storage.count else { throw WireError.truncated }
        defer { offset += count }
        return Array(storage[offset..<offset + count])
    }

    public mutating func data() throws -> [UInt8] {
        let n = try varUInt()
        return try readBytes(Int(n))
    }

    public mutating func string() throws -> String {
        let raw = try data()
        guard let s = String(bytes: raw, encoding: .utf8) else {
            throw WireError.malformed("invalid utf8")
        }
        return s
    }

    public mutating func bool() throws -> Bool {
        switch try uint8() {
        case 0: return false
        case 1: return true
        case let other: throw WireError.malformed("invalid bool \(other)")
        }
    }
}

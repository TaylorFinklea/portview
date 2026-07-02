import Testing
@testable import PortviewProtocol

@Suite struct BinaryCodecTests {
    @Test func fixedIntegersRoundTrip() throws {
        var w = BinaryWriter()
        w.putUInt8(0xAB)
        w.putUInt16(0x1234)
        w.putUInt32(0xDEADBEEF)
        w.putUInt64(0x0102030405060708)
        var r = BinaryReader(w.bytes)
        #expect(try r.uint8() == 0xAB)
        #expect(try r.uint16() == 0x1234)
        #expect(try r.uint32() == 0xDEADBEEF)
        #expect(try r.uint64() == 0x0102030405060708)
        #expect(r.isAtEnd)
    }

    @Test(arguments: [0, 1, 127, 128, 300, 16_384, UInt64.max])
    func varUIntRoundTrips(_ value: UInt64) throws {
        var w = BinaryWriter()
        w.putVarUInt(value)
        var r = BinaryReader(w.bytes)
        #expect(try r.varUInt() == value)
    }

    @Test func smallVarUIntIsOneByte() {
        var w = BinaryWriter()
        w.putVarUInt(127)
        #expect(w.bytes.count == 1)
    }

    @Test func dataAndStringRoundTrip() throws {
        var w = BinaryWriter()
        w.putData([1, 2, 3])
        w.putString("héllo 🪟")
        w.putBool(true)
        w.putBool(false)
        var r = BinaryReader(w.bytes)
        #expect(try r.data() == [1, 2, 3])
        #expect(try r.string() == "héllo 🪟")
        #expect(try r.bool() == true)
        #expect(try r.bool() == false)
    }

    @Test func readingPastEndThrows() {
        var r = BinaryReader([0x01])
        #expect(throws: WireError.truncated) {
            _ = try r.uint16()
        }
    }

    @Test func dataRejectsDeclaredLengthAboveIntMax() {
        var w = BinaryWriter()
        w.putVarUInt(UInt64(Int.max) + 1)
        var r = BinaryReader(w.bytes)
        #expect(throws: WireError.truncated) {
            _ = try r.data()
        }
    }

    @Test func readBytesDoesNotTrapNearIntMax() throws {
        var r = BinaryReader([1, 2, 3])
        _ = try r.uint8() // offset = 1, so an `offset + count` bounds check would overflow
        #expect(throws: WireError.truncated) {
            _ = try r.readBytes(Int.max)
        }
    }

    @Test func invalidBoolThrows() {
        var r = BinaryReader([0x02])
        #expect(throws: (any Error).self) {
            _ = try r.bool()
        }
    }
}

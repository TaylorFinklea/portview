import Testing
@testable import PortholeProtocol

@Suite struct KeyCursorMessageTests {
    @Test func keyEventRoundTripsForEveryKey() throws {
        for key in SpecialKey.allCases {
            var w = BinaryWriter()
            KeyEvent(key: key).encode(into: &w)
            var r = BinaryReader(w.bytes)
            #expect(try KeyEvent(from: &r) == KeyEvent(key: key))
        }
    }

    @Test func unknownSpecialKeyThrows() {
        var r = BinaryReader([200])
        #expect(throws: WireError.unknownEnum("SpecialKey", 200)) {
            _ = try KeyEvent(from: &r)
        }
    }

    @Test func cursorPositionRoundTrips() throws {
        let m = CursorPosition(nx: 12345, ny: 54321)
        var w = BinaryWriter()
        m.encode(into: &w)
        var r = BinaryReader(w.bytes)
        #expect(try CursorPosition(from: &r) == m)
    }

    @Test func cursorPositionNormalizationClampsAndScales() {
        let mid = CursorPosition(normalizedX: 0.5, normalizedY: 1.0)
        #expect(abs(mid.normalizedX - 0.5) < 0.001)
        #expect(mid.ny == 65535)
        let clamped = CursorPosition(normalizedX: -1, normalizedY: 2)
        #expect(clamped.nx == 0)
        #expect(clamped.ny == 65535)
    }

    @Test func keyAndCursorRoundTripThroughFrames() throws {
        let key: AnyMessage = .keyEvent(KeyEvent(key: .returnKey))
        let cursor: AnyMessage = .cursorPosition(CursorPosition(nx: 1, ny: 2))
        #expect(try Frame.decode(Frame.encodeAny(key)) == key)
        #expect(try Frame.decode(Frame.encodeAny(cursor)) == cursor)
    }
}

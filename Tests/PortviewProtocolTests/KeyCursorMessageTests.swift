// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import PortviewProtocol

@Suite struct KeyCursorMessageTests {
    @Test func keyEventRoundTripsForEveryKey() throws {
        for key in SpecialKey.allCases {
            let event = KeyEvent(special: key)
            var w = BinaryWriter()
            event.encode(into: &w)
            var r = BinaryReader(w.bytes)
            #expect(try KeyEvent(from: &r) == event)
        }
    }

    @Test func keyEventCarriesModifiers() throws {
        let event = KeyEvent(special: .arrowLeft, modifiers: [.command, .shift])
        var w = BinaryWriter()
        event.encode(into: &w)
        var r = BinaryReader(w.bytes)
        let decoded = try KeyEvent(from: &r)
        #expect(decoded == event)
        #expect(decoded.modifiers.contains(.command))
        #expect(decoded.modifiers.contains(.shift))
        #expect(!decoded.modifiers.contains(.option))
    }

    @Test func keyEventCharacterChordRoundTrips() throws {
        let event = KeyEvent(character: "c", modifiers: .command)
        var w = BinaryWriter()
        event.encode(into: &w)
        var r = BinaryReader(w.bytes)
        let decoded = try KeyEvent(from: &r)
        #expect(decoded == event)
        #expect(decoded.key == .character("c"))
    }

    @Test func unknownSpecialKeyThrows() {
        // [modifiers=0][kind=0 special][raw=200] → invalid SpecialKey
        var r = BinaryReader([0, 0, 200])
        #expect(throws: WireError.unknownEnum("SpecialKey", 200)) {
            _ = try KeyEvent(from: &r)
        }
    }

    @Test func unknownKeyKindThrows() {
        var r = BinaryReader([0, 9])  // kind 9 is not special(0)/character(1)
        #expect(throws: WireError.unknownEnum("KeyEvent.Key", 9)) {
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
        let key: AnyMessage = .keyEvent(KeyEvent(special: .returnKey))
        let cursor: AnyMessage = .cursorPosition(CursorPosition(nx: 1, ny: 2))
        #expect(try Frame.decode(Frame.encodeAny(key)) == key)
        #expect(try Frame.decode(Frame.encodeAny(cursor)) == cursor)
    }
}

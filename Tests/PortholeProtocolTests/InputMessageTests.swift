import Testing
@testable import PortholeProtocol

private func roundTrip<M: WireMessage>(_ message: M) throws -> M {
    var w = BinaryWriter()
    message.encode(into: &w)
    var r = BinaryReader(w.bytes)
    return try M(from: &r)
}

@Suite struct InputMessageTests {
    @Test func pointerMoveRoundTripsIncludingNegativeDeltas() throws {
        let m = PointerMove(dx: -17, dy: 42)
        #expect(try roundTrip(m) == m)
        #expect(PointerMove.messageType == .pointerMove)
    }

    @Test func pointerButtonRoundTrips() throws {
        for kind in PointerButtonKind.allCases {
            #expect(try roundTrip(PointerButton(button: kind, isDown: true)) == PointerButton(button: kind, isDown: true))
        }
        #expect(try roundTrip(PointerButton(button: .right, isDown: false)) == PointerButton(button: .right, isDown: false))
    }

    @Test func scrollRoundTrips() throws {
        let m = Scroll(dx: 3, dy: -120)
        #expect(try roundTrip(m) == m)
    }

    @Test func typeTextRoundTrips() throws {
        let m = TypeText(text: "héllo 🪟\n")
        #expect(try roundTrip(m) == m)
    }

    @Test func unknownPointerButtonByteThrows() {
        var r = BinaryReader([99, 1]) // button raw=99 (invalid), isDown=1
        #expect(throws: WireError.unknownEnum("PointerButtonKind", 99)) {
            _ = try PointerButton(from: &r)
        }
    }

    @Test func inputMessagesRoundTripThroughFrames() throws {
        let messages: [AnyMessage] = [
            .pointerMove(PointerMove(dx: -5, dy: 9)),
            .pointerButton(PointerButton(button: .left, isDown: true)),
            .scroll(Scroll(dx: 0, dy: -3)),
            .typeText(TypeText(text: "hi")),
        ]
        for message in messages {
            #expect(try Frame.decode(Frame.encodeAny(message)) == message)
        }
    }
}

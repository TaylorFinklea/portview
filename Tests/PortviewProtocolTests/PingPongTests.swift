// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import PortviewProtocol

@Suite struct PingPongTests {
    @Test func pingRoundTrips() throws {
        let message = Ping(sendMicros: 1_234_567_890_123)
        var w = BinaryWriter()
        message.encode(into: &w)
        var r = BinaryReader(w.bytes)
        #expect(try Ping(from: &r) == message)
        #expect(Ping.messageType == .ping)
    }

    @Test func pongRoundTrips() throws {
        let message = Pong(sendMicros: 1_234_567_890_123, hostUptimeMicros: 9_876_543_210)
        var w = BinaryWriter()
        message.encode(into: &w)
        var r = BinaryReader(w.bytes)
        #expect(try Pong(from: &r) == message)
        #expect(Pong.messageType == .pong)
    }

    @Test func pingThroughFrame() throws {
        let any: AnyMessage = .ping(Ping(sendMicros: 1_234_567_890_123))
        #expect(try Frame.decode(Frame.encodeAny(any)) == any)
    }

    @Test func pongThroughFrame() throws {
        let any: AnyMessage = .pong(Pong(sendMicros: 1_234_567_890_123, hostUptimeMicros: 9_876_543_210))
        #expect(try Frame.decode(Frame.encodeAny(any)) == any)
    }

    /// Pin the on-wire encoding so a refactor can't silently shift the tag or payload. Frame =
    /// [varint bodyLen][type byte][payload]; Ping is tag 27 with an 8-byte big-endian UInt64
    /// payload (bodyLen = 9); Pong is tag 28 with two 8-byte big-endian UInt64 fields (bodyLen = 17).
    @Test func pingPongWireBytesArePinned() {
        #expect(MessageType.ping.rawValue == 27)
        #expect(MessageType.pong.rawValue == 28)
        #expect(Frame.encodeAny(.ping(Ping(sendMicros: 1_234_567_890_123))) ==
            [9, 27, 0, 0, 1, 31, 113, 251, 4, 203])
        #expect(Frame.encodeAny(.pong(Pong(sendMicros: 1_234_567_890_123, hostUptimeMicros: 9_876_543_210))) ==
            [17, 28, 0, 0, 1, 31, 113, 251, 4, 203, 0, 0, 0, 2, 76, 176, 22, 234])
    }
}

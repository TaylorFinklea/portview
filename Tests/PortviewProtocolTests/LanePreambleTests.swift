// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import PortviewProtocol

/// Covers the stream-preamble codec (`[uint8 laneRawValue][32B sessionToken]`) that every
/// secondary QUIC lane stream writes once, first — see `LanePreamble`.
@Suite struct LanePreambleTests {
    @Test func roundTripsForEveryLane() throws {
        let token = (0..<32).map { UInt8($0) }
        for lane in Lane.allCases {
            let m = LanePreamble(lane: lane, sessionToken: token)
            let decoded = try LanePreamble.decode(m.encode())
            #expect(decoded == m)
        }
    }

    @Test func laneStatsPreambleWireBytesArePinned() {
        let token = Array(repeating: UInt8(0x5A), count: 32)
        let m = LanePreamble(lane: .stats, sessionToken: token)
        #expect(m.encode() == [
            6,
            90, 90, 90, 90, 90, 90, 90, 90, 90, 90, 90, 90, 90, 90, 90, 90,
            90, 90, 90, 90, 90, 90, 90, 90, 90, 90, 90, 90, 90, 90, 90, 90,
        ])
    }

    @Test func laneControlPreambleWireBytesArePinned() {
        let token = Array(repeating: UInt8(0xAB), count: 32)
        let m = LanePreamble(lane: .control, sessionToken: token)
        #expect(m.encode() == [
            0,
            171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171,
            171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171,
        ])
    }

    @Test func unknownLaneByteThrows() {
        let bytes = [UInt8(7)] + Array(repeating: UInt8(0), count: 32)
        #expect(throws: WireError.unknownEnum("Lane", 7)) {
            _ = try LanePreamble.decode(bytes)
        }
    }

    @Test func truncatedTokenThrows() {
        let bytes = [UInt8(Lane.video.rawValue)] + Array(repeating: UInt8(0), count: 10)
        #expect(throws: WireError.truncated) {
            _ = try LanePreamble.decode(bytes)
        }
    }

    @Test func tokenLengthIsThirtyTwoBytes() {
        #expect(LanePreamble.tokenLength == 32)
    }
}

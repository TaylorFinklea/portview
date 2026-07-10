// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import PortviewClientCore

@Suite struct HexDataTests {
    @Test func parsesValidHex() {
        #expect(Data(hexString: "deadBEEF") == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    @Test func trimsSurroundingWhitespace() {
        #expect(Data(hexString: "  0a0b \n") == Data([0x0A, 0x0B]))
    }

    @Test func rejectsOddLength() {
        #expect(Data(hexString: "abc") == nil)
    }

    @Test func rejectsNonHexCharacters() {
        #expect(Data(hexString: "zz") == nil)
    }

    @Test func emptyStringYieldsEmptyData() {
        #expect(Data(hexString: "") == Data())
    }
}

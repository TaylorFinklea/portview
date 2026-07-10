// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import PortviewTransport

@Suite struct PairingPayloadTests {
    @Test func roundTripsThroughURLString() {
        let payload = PairingPayload(host: "10.0.0.5", port: 54321, pinHex: "deadbeef", name: "Taylor's Mac")
        let parsed = PairingPayload(urlString: payload.urlString)
        #expect(parsed == payload)
    }

    @Test func roundTripsWithoutName() {
        let payload = PairingPayload(host: "192.168.1.2", port: 7000, pinHex: "abc123")
        let parsed = PairingPayload(urlString: payload.urlString)
        #expect(parsed == payload)
    }

    @Test func rejectsForeignScheme() {
        #expect(PairingPayload(urlString: "https://pair?host=x&port=1&pin=y") == nil)
    }

    @Test func rejectsMissingFields() {
        #expect(PairingPayload(urlString: "portview://pair?host=x&pin=y") == nil) // no port
        #expect(PairingPayload(urlString: "portview://pair?port=99999999&host=x&pin=y") == nil) // port overflows UInt16
    }
}
